#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_config.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from pathlib import Path

import pytest

from netdef_ci.config import Settings


def make(**env: str) -> Settings:
    return Settings(_env_file=None, **env)  # type: ignore[call-arg]


def test_ci_url_accepts_bare_host_and_url() -> None:
    assert make(CI_URL="ci1.netdef.org").ci_url == "ci1.netdef.org"
    assert make(CI_URL="https://ci1.netdef.org/").ci_url == "ci1.netdef.org"
    assert make(CI_URL="ci1.netdef.org").browse_url("PROJ-1") == "https://ci1.netdef.org/browse/PROJ-1"


def test_github_apps_file_keys(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GITHUB_APPS_FILE", raising=False)
    file = tmp_path / "apps.toml"
    file.write_text(
        '[[github_apps]]\nlogin = 1234567\ncert = "/k.pem"\nrepo = "org/a"\n\n[[github_apps]]\nlogin = "99"\ncert = "/k2.pem"\n'
    )
    apps = make(GITHUB_APPS_FILE=str(file)).github_apps()
    assert [(a.login, a.cert, a.repo) for a in apps] == [("1234567", "/k.pem", "org/a"), ("99", "/k2.pem", None)]
    assert make().github_apps() == []


def test_credentials_prefer_env_then_netrc(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    netrc = tmp_path / ".netrc"
    netrc.write_text("machine ci1.netdef.org login fromnetrc password pw\n")
    netrc.chmod(0o600)
    monkeypatch.setenv("HOME", str(tmp_path))
    for name in ("BAMBOO_USERNAME", "BAMBOO_PASSWORD"):
        monkeypatch.delenv(name)
    assert make().bamboo_credentials().username == "fromnetrc"  # type: ignore[union-attr]
    assert make(BAMBOO_USERNAME="env", BAMBOO_PASSWORD="p").bamboo_credentials().username == "env"  # type: ignore[union-attr]


def test_secrets_are_not_leaked_by_repr() -> None:
    assert "topsecret" not in repr(make(WEBHOOK_SECRET="topsecret"))
