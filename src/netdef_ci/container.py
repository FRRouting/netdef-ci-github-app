#  SPDX-License-Identifier: BSD-2-Clause
#
#  container.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Process-wide wiring of the external clients. Tests replace them with `override()`."""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Any

import httpx

from netdef_ci.clients.bamboo import BambooClient
from netdef_ci.clients.github import GithubCheck, reset_app_auth_registry
from netdef_ci.clients.slack import SlackBot
from netdef_ci.config import get_settings

_lock = threading.Lock()
_instances: dict[str, Any] = {}
_github_client: httpx.Client | None = None
_github_factory: Callable[[Any], GithubCheck] | None = None


def bamboo() -> BambooClient:
    with _lock:
        if "bamboo" not in _instances:
            _instances["bamboo"] = BambooClient(get_settings())
        return _instances["bamboo"]  # type: ignore[no-any-return]


def slack() -> SlackBot:
    with _lock:
        if "slack" not in _instances:
            _instances["slack"] = SlackBot(get_settings())
        return _instances["slack"]  # type: ignore[no-any-return]


def github(check_suite: Any | None = None) -> GithubCheck:
    """Equivalent of `Github::Check.new(check_suite)`."""
    global _github_client
    if _github_factory is not None:
        return _github_factory(check_suite)
    with _lock:
        if _github_client is None:
            _github_client = httpx.Client(timeout=get_settings().http_timeout_seconds)
    return GithubCheck(check_suite, get_settings(), client=_github_client)


def override(*, bamboo: Any = None, slack: Any = None, github_factory: Callable[[Any], Any] | None = None) -> None:
    """Replace clients (tests)."""
    global _github_factory
    with _lock:
        if bamboo is not None:
            _instances["bamboo"] = bamboo
        if slack is not None:
            _instances["slack"] = slack
    if github_factory is not None:
        _github_factory = github_factory


def reset() -> None:
    global _github_client, _github_factory
    with _lock:
        _instances.clear()
    _github_factory = None
    reset_app_auth_registry()
    if _github_client is not None:
        _github_client.close()
        _github_client = None
