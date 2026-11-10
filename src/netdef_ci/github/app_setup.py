#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/app_setup.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`create-github-app`: creates the GitHub App of a new environment from a manifest (one click on GitHub), stores
its key and the webhook secret in the environment's Ansible vault, waits for the installation (second click) and runs
the `check-github` checks. Runs on the operator's machine, which has a browser and the inventory."""

from __future__ import annotations

import html
import json
import os
import re
import secrets
import shutil
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

from netdef_ci.clients.github import GithubAppApi, account_type, convert_app_manifest
from netdef_ci.github.app_check import REQUIRED_EVENTS, REQUIRED_PERMISSIONS, AppCheck, AppReport
from netdef_ci.helpers.config import GitHubAppConfig, Settings

# Discussions is not used by the code; it is kept for parity with the App created by hand (doc/13, step 2).
MANIFEST_PERMISSIONS = {**REQUIRED_PERMISSIONS, "discussions": "write"}
APPS_KEY = "vault_netdef_ci_github_apps"
SECRET_KEY = "vault_netdef_ci_webhook_secret"
WEBHOOK_URL_KEY = "netdef_ci_webhook_public_url"
KEY_PLACEHOLDER = "REPLACE_WITH_THE_APP_PRIVATE_KEY"
MIN_SECRET_LENGTH = 16  # the Ansible role refuses shorter production secrets
INSTALLATION_POLL_SECONDS = 5.0

Runner = Callable[..., subprocess.CompletedProcess[str]]


class AppSetupError(Exception):
    """A precondition failed; the message tells the operator what to do."""


# ----- manifest
def build_manifest(name: str, webhook_url: str, redirect_url: str, homepage_url: str) -> dict[str, Any]:
    """GitHub App manifest with the settings of doc/13, step 2 (private: installable only on its owner account)."""
    return {
        "name": name,
        "url": homepage_url,
        "hook_attributes": {"url": webhook_url, "active": True},
        "redirect_url": redirect_url,
        "public": False,
        "default_permissions": MANIFEST_PERMISSIONS,
        "default_events": sorted(REQUIRED_EVENTS),
        "request_oauth_on_install": False,
    }


def github_web_url(settings: Settings) -> str:
    """`https://github.com` for the public API; `<host>` for GitHub Enterprise (`<host>/api/v3`)."""
    api = settings.github_api_url.rstrip("/")
    return "https://github.com" if api == "https://api.github.com" else api.removesuffix("/api/v3")


def creation_url(web_url: str, owner: str, is_organization: bool, state: str) -> str:
    path = f"/organizations/{owner}/settings/apps/new" if is_organization else "/settings/apps/new"
    return f"{web_url}{path}?{urlencode({'state': state})}"


class ManifestCallback:
    """Local HTTP server (127.0.0.1) that posts the manifest to GitHub and receives the redirect with the code."""

    def __init__(self, manifest_for: Callable[[str], dict[str, Any]], action_url: Callable[[str], str]) -> None:
        self.state = secrets.token_urlsafe(16)
        self.code: str | None = None
        callback = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                if parsed.path == "/":
                    manifest = json.dumps(manifest_for(callback.redirect_url))
                    self._send(200, _form_page(action_url(callback.state), manifest))
                elif parsed.path == "/callback":
                    query = parse_qs(parsed.query)
                    if query.get("state", [""])[0] != callback.state or not query.get("code"):
                        self._send(400, _page("Invalid callback", "The state does not match; start again."))
                        return
                    callback.code = query["code"][0]
                    self._send(200, _page("GitHub App created", "Go back to the terminal to continue."))
                else:
                    self._send(404, _page("Not found", ""))

            def _send(self, status: int, body: str) -> None:
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, format: str, *args: Any) -> None:  # the callback code must not reach stderr
                return

        self._server = HTTPServer(("127.0.0.1", 0), Handler)
        self._server.timeout = 0.5

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self._server.server_address[1]}/"

    @property
    def redirect_url(self) -> str:
        return f"{self.url}callback"

    def wait_for_code(self, timeout_seconds: float) -> str:
        deadline = time.monotonic() + timeout_seconds
        try:
            while self.code is None and time.monotonic() < deadline:
                self._server.handle_request()
        finally:
            self._server.server_close()
        if self.code is None:
            raise AppSetupError(f"GitHub did not redirect back within {timeout_seconds:g} s; run the command again")
        return self.code


def _page(title: str, text: str) -> str:
    return f"<!doctype html><meta charset=utf-8><title>{title}</title><h1>{title}</h1><p>{html.escape(text)}</p>"


def _form_page(action: str, manifest: str) -> str:
    return (
        "<!doctype html><meta charset=utf-8><title>Create the GitHub App</title>"
        f'<form id=f method=post action="{html.escape(action)}">'
        f'<input type=hidden name=manifest value="{html.escape(manifest)}">'
        "<button>Continue to GitHub</button></form>"
        "<script>document.getElementById('f').submit()</script>"
    )


# ----- vault and inventory files
class VaultFile:
    """One encrypted vault file, read and written through `ansible-vault`; the plain text and the password only travel
    through pipes, never through the disk."""

    def __init__(self, path: Path, password: str, run: Runner = subprocess.run) -> None:
        self.path = path
        self._password = password
        self._run = run

    def exists(self) -> bool:
        return self.path.exists()

    def read(self) -> str:
        return self._vault(["decrypt", "--output", "-", str(self.path)])

    def write(self, text: str) -> None:
        tmp = self.path.with_name(self.path.name + ".tmp")
        self._vault(["encrypt", "--output", str(tmp), "-"], text)
        os.replace(tmp, self.path)

    def _vault(self, args: list[str], text: str | None = None) -> str:
        if shutil.which("ansible-vault") is None:
            raise AppSetupError("ansible-vault not found: install ansible-core on this machine")
        read_fd, write_fd = os.pipe()
        os.write(write_fd, self._password.encode() + b"\n")
        os.close(write_fd)
        try:
            result = self._run(
                ["ansible-vault", *args[:1], "--vault-password-file", f"/dev/fd/{read_fd}", *args[1:]],
                input=text,
                capture_output=True,
                text=True,
                pass_fds=(read_fd,),
                check=False,
            )
        finally:
            os.close(read_fd)
        if result.returncode != 0:
            raise AppSetupError(f"ansible-vault {args[0]} failed: {result.stderr.strip()[-300:]}")
        return result.stdout


def _q(value: str) -> str:
    """YAML double-quoted scalar (JSON strings are valid YAML)."""
    return json.dumps(value)


def _block(lines: list[str], key: str) -> tuple[int, int] | None:
    """[start, end) of a top-level key and its indented continuation lines."""
    pattern = re.compile(rf"^{re.escape(key)}\s*:")
    start = next((i for i, line in enumerate(lines) if pattern.match(line)), None)
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and (not lines[end].strip() or lines[end][0] in " \t"):
        end += 1
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return start, end


def set_top_level(text: str, key: str, block: str) -> str:
    """Replaces the top-level `key` (with its nested lines) by `block`, or appends it."""
    lines = text.splitlines(keepends=True)
    found = _block(lines, key)
    if found is None:
        return (text if not text or text.endswith("\n") else text + "\n") + block
    start, end = found
    return "".join(lines[:start]) + block + "".join(lines[end:])


def top_level_value(text: str, key: str) -> str | None:
    match = re.search(rf"^{re.escape(key)}\s*:\s*(.*?)\s*$", text, re.MULTILINE)
    if match is None:
        return None
    value = match.group(1)
    return value[1:-1] if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'" else value


def ensure_webhook_secret(text: str) -> tuple[str, str, bool]:
    """Keeps the environment's secret (shared with Bamboo and other Apps) or generates one for a placeholder.
    Returns (text, secret, generated)."""
    current = top_level_value(text, SECRET_KEY) or ""
    if len(current) >= MIN_SECRET_LENGTH and "CHANGE_ME" not in current:
        return text, current, False
    secret = secrets.token_hex(32)
    return set_top_level(text, SECRET_KEY, f"{SECRET_KEY}: {_q(secret)}\n"), secret, True


def add_github_app(text: str, login: str, repo: str, pem: str) -> str:
    """Adds the App to `vault_netdef_ci_github_apps`, replacing the example placeholder."""
    entry = f"  - login: {_q(login)}\n    repo: {_q(repo)}\n    private_key: |\n" + "".join(
        f"      {line}\n" for line in pem.strip().splitlines()
    )
    lines = text.splitlines(keepends=True)
    found = _block(lines, APPS_KEY)
    if found is None or KEY_PLACEHOLDER in "".join(lines[found[0] : found[1]]):
        return set_top_level(text, APPS_KEY, f"{APPS_KEY}:\n{entry}")
    start, end = found
    current = "".join(lines[start:end])
    if re.search(rf"^\s*-?\s*repo:\s*[\"']?{re.escape(repo)}[\"']?\s*$", current, re.MULTILINE | re.IGNORECASE):
        raise AppSetupError(f"{APPS_KEY} already has an App for {repo}; remove that entry first")
    return "".join(lines[:end]) + entry + "".join(lines[end:])


# ----- the flow
@dataclass
class AppSetupRequest:
    inventory: Path  # deploy/ansible/inventories/<env>
    repo: str  # <owner>/<repo>
    webhook_url: str
    name: str | None = None
    timeout_seconds: float = 15 * 60

    @property
    def owner(self) -> str:
        return self.repo.split("/", 1)[0]

    @property
    def vault_path(self) -> Path:
        return self.inventory / "group_vars" / "all" / "vault.yml"

    @property
    def main_vars_path(self) -> Path:
        return self.inventory / "group_vars" / "all" / "main.yml"


class CreateGithubApp:
    def __init__(
        self,
        request: AppSetupRequest,
        settings: Settings,
        vault: VaultFile,
        *,
        client: httpx.Client,
        open_browser: Callable[[str], object],
        notify: Callable[[str], None],
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.request = request
        self.settings = settings
        self.vault = vault
        self.client = client
        self.open_browser = open_browser
        self.notify = notify
        self.sleep = sleep

    def run(self) -> AppReport:
        request = self.request
        if "/" not in request.repo or not (request.inventory / "hosts.yml").is_file():
            raise AppSetupError(f"{request.inventory}/hosts.yml not found or --repo is not <owner>/<repo>")
        # Read the vault first: a wrong password must stop us before an App exists that nothing records.
        text = self._initial_vault_text()
        is_org = account_type(self.settings, request.owner, self.client) == "Organization"
        web = github_web_url(self.settings)
        name = request.name or f"NetDEF CI {request.inventory.name}"
        callback = ManifestCallback(
            lambda redirect: build_manifest(name, request.webhook_url, redirect, f"{web}/{request.repo}"),
            lambda state: creation_url(web, request.owner, is_org, state),
        )
        account = f"organization {request.owner}" if is_org else f"account {request.owner} (log in as that user)"
        self.notify(f"1/2 In the browser, check the form and click 'Create GitHub App' for the {account}.")
        self.notify(f"    If the browser does not open, visit {callback.url}")
        self.open_browser(callback.url)
        app = convert_app_manifest(self.settings, callback.wait_for_code(request.timeout_seconds), self.client)
        login, pem = str(app["id"]), str(app["pem"])
        self.notify(f"App {app.get('slug')} created (App ID {login}).")

        text, secret, generated = ensure_webhook_secret(text)
        self.vault.write(add_github_app(text, login, request.repo, pem))
        self.notify(f"App ID, repository and private key saved in {request.vault_path}.")
        if generated:
            self.notify("A new webhook secret was generated and saved in the vault (the Bamboo plan uses it too).")
        self._save_webhook_url()

        api = GithubAppApi(
            GitHubAppConfig(login, "(in memory)", request.repo),
            self.settings,
            client=self.client,
            sleep=self.sleep,
            private_key=pem.encode(),
        )
        api.update_hook_config(request.webhook_url, secret)
        self.notify("Webhook URL and secret set on the App.")

        install_url = f"{app.get('html_url')}/installations/new"
        self.notify(f"2/2 In the browser, choose 'Only select repositories', select {request.repo} and click Install.")
        self.notify(f"    If the browser does not open, visit {install_url}")
        self.open_browser(install_url)
        self._wait_for_installation(api)
        return AppCheck(api, webhook_url=request.webhook_url, sleep=self.sleep).run()

    def _initial_vault_text(self) -> str:
        if self.vault.exists():
            return self.vault.read()
        example = self.request.vault_path.with_name("vault.yml.example")
        self.notify(f"{self.request.vault_path} does not exist: it is created from {example.name}.")
        return example.read_text() if example.is_file() else "---\n"

    def _save_webhook_url(self) -> None:
        path = self.request.main_vars_path
        text = path.read_text() if path.is_file() else "---\n"
        path.write_text(set_top_level(text, WEBHOOK_URL_KEY, f"{WEBHOOK_URL_KEY}: {_q(self.request.webhook_url)}\n"))
        self.notify(f"{WEBHOOK_URL_KEY} saved in {path} (compared by check-github after each deploy).")

    def _wait_for_installation(self, api: GithubAppApi) -> None:
        waited = 0.0
        while not api.installations():
            if waited >= self.request.timeout_seconds:
                raise AppSetupError(
                    "the App was created and saved in the vault, but it is not installed yet: install it and run "
                    "check-github"
                )
            self.sleep(INSTALLATION_POLL_SECONDS)
            waited += INSTALLATION_POLL_SECONDS
        self.notify("App installed.")
