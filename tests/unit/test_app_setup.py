#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_app_setup.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""`create-github-app`: manifest flow, vault and inventory edits, installation wait."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import threading
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from html import unescape
from pathlib import Path

import httpx
import pytest
import respx
from cryptography.hazmat.primitives import serialization

from netdef_ci.cli.main import main
from netdef_ci.github import app_setup
from netdef_ci.github.app_setup import (
    AppSetupError,
    AppSetupRequest,
    CreateGithubApp,
    ManifestCallback,
    VaultFile,
    add_github_app,
    build_manifest,
    creation_url,
    ensure_webhook_secret,
    github_web_url,
    set_top_level,
    top_level_value,
)

API = "https://api.github.com"
ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "deploy/ansible/inventories/dev/group_vars/all/vault.yml.example"
PEM_PLACEHOLDER = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"


class MemoryVault(VaultFile):
    def __init__(self, text: str | None = None) -> None:
        super().__init__(Path("unused"), "pw")
        self.text = text
        self.writes = 0

    def exists(self) -> bool:
        return self.text is not None

    def read(self) -> str:
        assert self.text is not None
        return self.text

    def write(self, text: str) -> None:
        self.text = text
        self.writes += 1


class Browser:
    """Plays the user: submits the manifest page (GitHub redirects with a code) and records every URL opened."""

    def __init__(self, code: str = "the-code") -> None:
        self.opened: list[str] = []
        self.code = code
        self.manifest: dict[str, object] | None = None
        self.action = ""
        self._threads: list[threading.Thread] = []

    def __call__(self, url: str) -> bool:
        self.opened.append(url)
        if url.startswith("http://127.0.0.1"):
            thread = threading.Thread(target=self._create, args=(url,))
            thread.start()
            self._threads.append(thread)
        return True

    def _create(self, url: str) -> None:
        with httpx.Client() as client:
            page = client.get(url).text
            self.action = unescape(re.search(r'action="([^"]+)"', page).group(1))  # type: ignore[union-attr]
            self.manifest = json.loads(unescape(re.search(r'value="([^"]+)"', page).group(1)))  # type: ignore[union-attr]
            state = self.action.split("state=")[1]
            client.get(f"{url}callback", params={"code": self.code, "state": state})

    def join(self) -> None:
        for thread in self._threads:
            thread.join(5)


@pytest.fixture
def inventory(tmp_path: Path) -> Path:
    inv = tmp_path / "inventories" / "newenv"
    (inv / "group_vars" / "all").mkdir(parents=True)
    (inv / "hosts.yml").write_text("all: {}\n")
    (inv / "group_vars" / "all" / "main.yml").write_text("---\nnetdef_ci_env: development\n")
    shutil.copy(EXAMPLE, inv / "group_vars" / "all" / "vault.yml.example")
    return inv


@pytest.fixture
def pem(rsa_key) -> str:
    return rsa_key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()
    ).decode()


@pytest.fixture
def github(pem: str) -> Iterator[respx.MockRouter]:
    expires = (datetime.now(UTC) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    installation = {
        "id": 7,
        "account": {"login": "someone"},
        "permissions": app_setup.MANIFEST_PERMISSIONS,
        "repository_selection": "selected",
        "html_url": "https://github.com/settings/installations/7",
    }
    with respx.mock(assert_all_called=False) as router:
        router.route(host="127.0.0.1").pass_through()
        router.get(f"{API}/users/someone", name="user").respond(200, json={"type": "User"})
        router.post(f"{API}/app-manifests/the-code/conversions", name="convert").respond(
            201,
            json={
                "id": 424242,
                "slug": "netdef-ci-newenv",
                "html_url": "https://github.com/apps/netdef-ci-newenv",
                "pem": pem,
            },
        )
        router.patch(f"{API}/app/hook/config", name="patch_hook").respond(200, json={})
        polls = iter([[]])  # not installed at the first poll, installed afterwards
        router.get(f"{API}/app/installations", name="installations").mock(
            side_effect=lambda _request: httpx.Response(200, json=next(polls, [installation]))
        )
        router.post(f"{API}/app/installations/7/access_tokens").respond(
            201, json={"token": "ghs_tokentoken", "expires_at": expires}
        )
        router.get(f"{API}/app", name="app").respond(
            200,
            json={
                "slug": "netdef-ci-newenv",
                "owner": {"login": "someone"},
                "html_url": "https://github.com/apps/netdef-ci-newenv",
                "permissions": app_setup.MANIFEST_PERMISSIONS,
                "events": sorted(app_setup.REQUIRED_EVENTS),
            },
        )
        router.get(f"{API}/installation/repositories").respond(
            200, json={"repositories": [{"full_name": "someone/frr"}]}
        )
        router.get(f"{API}/app/hook/config").respond(
            200, json={"url": "https://ci.example.org/githubcheck", "content_type": "json", "insecure_ssl": "0"}
        )
        router.get(f"{API}/app/hook/deliveries").respond(200, json=[])
        yield router


def make(inventory: Path, settings, vault: VaultFile, browser: Browser, messages: list[str], sleeps: list[float]):
    request = AppSetupRequest(inventory, "someone/frr", "https://ci.example.org/githubcheck", timeout_seconds=30)
    return CreateGithubApp(
        request,
        settings,
        vault,
        client=httpx.Client(),
        open_browser=browser,
        notify=messages.append,
        sleep=sleeps.append,
    )


# ----- the whole flow
def test_new_environment_creates_stores_installs_and_checks_the_app(github, inventory, settings, pem) -> None:
    vault, browser, messages, sleeps = MemoryVault(), Browser(), [], []
    report = make(inventory, settings, vault, browser, messages, sleeps).run()
    browser.join()

    # GitHub form: personal account, every setting of doc/13 step 2, redirect to the local server
    assert browser.action.startswith("https://github.com/settings/apps/new?state=")
    assert browser.manifest is not None
    assert browser.manifest["name"] == "NetDEF CI newenv"
    assert browser.manifest["public"] is False
    assert browser.manifest["hook_attributes"] == {"url": "https://ci.example.org/githubcheck", "active": True}
    assert browser.opened[1] == "https://github.com/apps/netdef-ci-newenv/installations/new"

    # vault: created from the example, placeholder App replaced, secret generated
    assert vault.writes == 1 and vault.text is not None
    assert app_setup.KEY_PLACEHOLDER not in vault.text
    assert 'login: "424242"' in vault.text and 'repo: "someone/frr"' in vault.text
    assert "      " + pem.strip().splitlines()[1] in vault.text
    secret = top_level_value(vault.text, app_setup.SECRET_KEY)
    assert secret is not None and len(secret) == 64
    assert top_level_value(vault.text, "vault_netdef_ci_bamboo_username") == "ci-bot"  # other keys kept

    # the App uses the vault's secret, and the inventory knows the webhook URL
    assert json.loads(github.routes["patch_hook"].calls[0].request.content) == {
        "url": "https://ci.example.org/githubcheck",
        "content_type": "json",
        "insecure_ssl": "0",
        "secret": secret,
    }
    main_vars = (inventory / "group_vars/all/main.yml").read_text()
    assert 'netdef_ci_webhook_public_url: "https://ci.example.org/githubcheck"' in main_vars

    assert sleeps == [app_setup.INSTALLATION_POLL_SECONDS]  # one poll before the installation appeared
    assert "App installed." in messages
    assert not report.failed
    assert ("ok", "repository someone/frr accessible") in report.findings


def test_existing_vault_keeps_its_webhook_secret(github, inventory, settings) -> None:
    existing = "vault_netdef_ci_webhook_secret: 'an-existing-secret-of-the-environment'\n"
    vault, browser = MemoryVault(existing), Browser()
    make(inventory, settings, vault, browser, [], []).run()
    browser.join()
    sent = json.loads(github.routes["patch_hook"].calls[0].request.content)
    assert sent["secret"] == "an-existing-secret-of-the-environment"
    assert vault.text is not None and vault.text.startswith(existing)


def test_organization_owner_uses_the_organization_form(github, inventory, settings) -> None:
    github.routes["user"].respond(200, json={"type": "Organization"})
    browser = Browser()
    make(inventory, settings, MemoryVault(), browser, [], []).run()
    browser.join()
    assert browser.action.startswith("https://github.com/organizations/someone/settings/apps/new?state=")


def test_installation_timeout_says_the_app_is_already_saved(github, inventory, settings) -> None:
    github.routes["installations"].side_effect = None
    github.routes["installations"].respond(200, json=[])
    vault, browser = MemoryVault(), Browser()
    with pytest.raises(AppSetupError, match="saved in the vault, but it is not installed"):
        make(inventory, settings, vault, browser, [], []).run()
    browser.join()
    assert vault.writes == 1


def test_missing_inventory_stops_before_github(github, tmp_path, settings) -> None:
    with pytest.raises(AppSetupError, match=r"hosts\.yml not found"):
        make(tmp_path / "nope", settings, MemoryVault(), Browser(), [], []).run()
    assert github.routes["user"].call_count == 0


# ----- pieces
def test_manifest_and_urls() -> None:
    manifest = build_manifest("CI", "https://h/githubcheck", "http://127.0.0.1:1/callback", "https://github.com/o/r")
    assert manifest["default_events"] == ["check_run", "check_suite", "issue_comment", "pull_request"]
    assert manifest["default_permissions"]["checks"] == "write"
    assert manifest["request_oauth_on_install"] is False
    assert (
        creation_url("https://github.com", "org", True, "s")
        == "https://github.com/organizations/org/settings/apps/new?state=s"
    )
    assert creation_url("https://github.com", "me", False, "s") == "https://github.com/settings/apps/new?state=s"


@pytest.mark.parametrize(
    ("api", "web"),
    [("https://api.github.com", "https://github.com"), ("https://ghe.example.org/api/v3", "https://ghe.example.org")],
)
def test_github_web_url(monkeypatch, settings, api, web) -> None:
    monkeypatch.setattr(settings, "github_api_url", api)
    assert github_web_url(settings) == web


def test_callback_rejects_a_wrong_state_and_unknown_paths() -> None:
    callback = ManifestCallback(lambda r: {"redirect_url": r}, lambda s: f"https://github.com/new?state={s}")
    results: list[int] = []

    def visit() -> None:
        with httpx.Client() as client:
            results.append(client.get(f"{callback.url}callback", params={"code": "x", "state": "forged"}).status_code)
            results.append(client.get(f"{callback.url}other").status_code)

    with respx.mock(assert_all_called=False) as router:
        router.route(host="127.0.0.1").pass_through()
        thread = threading.Thread(target=visit)
        thread.start()
        with pytest.raises(AppSetupError, match="did not redirect back"):
            callback.wait_for_code(2)
        thread.join(5)
    assert results == [400, 404]


def test_webhook_secret_rules() -> None:
    text, secret, generated = ensure_webhook_secret('vault_netdef_ci_webhook_secret: "CHANGE_ME_long_random_value"\n')
    assert generated and text == f'vault_netdef_ci_webhook_secret: "{secret}"\n'
    text, secret, generated = ensure_webhook_secret("a: 1\n")
    assert generated and text.startswith("a: 1\nvault_netdef_ci_webhook_secret:")
    assert ensure_webhook_secret("vault_netdef_ci_webhook_secret: short\n")[2]


def test_set_top_level_replaces_only_its_block() -> None:
    text = "a: 1\nb:\n  - x\n\n  - y\n\n# comment of c\nc: 3"
    assert set_top_level(text, "b", "b: []\n") == "a: 1\nb: []\n\n# comment of c\nc: 3"
    assert set_top_level(text, "d", "d: 4\n").endswith("c: 3\nd: 4\n")
    assert top_level_value("k: 'v'\n", "k") == "v" and top_level_value("k: v\n", "missing") is None


def test_add_github_app_appends_to_real_apps_and_refuses_the_same_repo() -> None:
    first = add_github_app("vault_netdef_ci_github_apps:\n", "1", "org/a", PEM_PLACEHOLDER)
    both = add_github_app(first + "other: 1\n", "2", "org/b", PEM_PLACEHOLDER)
    assert both.index('login: "1"') < both.index('login: "2"') < both.index("other: 1")
    with pytest.raises(AppSetupError, match="already has an App for ORG/A"):
        add_github_app(both, "3", "ORG/A", PEM_PLACEHOLDER)


@pytest.mark.skipif(shutil.which("ansible-vault") is None, reason="ansible-vault not installed")
def test_vault_file_round_trip_with_ansible_vault(tmp_path) -> None:
    vault = VaultFile(tmp_path / "vault.yml", "s3cret")
    assert not vault.exists()
    vault.write("a: 1\n")
    assert (tmp_path / "vault.yml").read_text().startswith("$ANSIBLE_VAULT;")
    assert vault.read() == "a: 1\n"
    with pytest.raises(AppSetupError, match="ansible-vault decrypt failed"):
        VaultFile(tmp_path / "vault.yml", "wrong").read()


def test_vault_file_without_ansible_vault(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(app_setup.shutil, "which", lambda _name: None)
    with pytest.raises(AppSetupError, match="ansible-vault not found"):
        VaultFile(tmp_path / "vault.yml", "pw").read()


def test_vault_file_passes_the_password_through_a_pipe(monkeypatch, tmp_path) -> None:
    calls: list[tuple[list[str], dict[str, object]]] = []

    def run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append((argv, kwargs))
        Path(argv[argv.index("--output") + 1]).write_text("encrypted")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(app_setup.shutil, "which", lambda _name: "/usr/bin/ansible-vault")
    VaultFile(tmp_path / "vault.yml", "pw", run=run).write("plain")
    argv, kwargs = calls[0]
    assert argv[:3] == ["ansible-vault", "encrypt", "--vault-password-file"]
    assert argv[3] == f"/dev/fd/{kwargs['pass_fds'][0]}"  # type: ignore[index]
    assert kwargs["input"] == "plain"
    assert (tmp_path / "vault.yml").read_text() == "encrypted"


# ----- command line
def test_command_runs_the_flow_and_prints_the_next_step(github, inventory, monkeypatch, capsys, tmp_path) -> None:
    vault = MemoryVault()
    browser = Browser()
    monkeypatch.setattr(app_setup, "VaultFile", lambda _path, _password: vault)
    monkeypatch.setattr("webbrowser.open", browser)
    password = tmp_path / "pass"
    password.write_text("pw\n")
    argv = ["create-github-app", "--inventory", str(inventory), "--repo", "someone/frr"]
    argv += ["--webhook-url", "https://ci.example.org/githubcheck", "--vault-password-file", str(password)]
    assert main(argv) == 0
    browser.join()
    out = capsys.readouterr().out
    assert "GitHub App 424242:" in out
    assert "playbooks/deploy.yml" in out and "inventories/newenv/hosts.yml" in out


def test_command_refuses_mismatched_new_vault_passwords(inventory, monkeypatch, capsys) -> None:
    answers = iter(["one", "two"])
    monkeypatch.setattr("getpass.getpass", lambda _prompt: next(answers))
    argv = ["create-github-app", "--inventory", str(inventory), "--repo", "o/r", "--webhook-url", "https://h/x"]
    assert main(argv) == 1
    assert "do not match" in capsys.readouterr().err


def test_command_reports_setup_errors(tmp_path, monkeypatch, capsys) -> None:
    monkeypatch.setattr("getpass.getpass", lambda _prompt: "pw")
    argv = ["create-github-app", "--inventory", str(tmp_path), "--repo", "o/r", "--webhook-url", "https://h/x"]
    assert main(argv) == 1
    assert "hosts.yml not found" in capsys.readouterr().err
