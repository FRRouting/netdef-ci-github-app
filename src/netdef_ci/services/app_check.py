#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/app_check.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`check-github`: verifies each configured GitHub App against what the service needs (key, a single installation,
repository access, permissions, events, webhook configuration and deliveries) and can redeliver the last `ping`."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import httpx

from netdef_ci import container
from netdef_ci.clients.github import GithubAppApi, GithubError
from netdef_ci.config import GitHubAppConfig

# Repository permissions used by the code (doc/13-github-app-setup.md, step 2); metadata is mandatory for every App.
REQUIRED_PERMISSIONS = {"checks": "write", "pull_requests": "write", "issues": "write", "metadata": "read"}
# Events handled by web/webhooks.py; `ping` and `installation` are sent without a subscription.
REQUIRED_EVENTS = frozenset({"check_run", "check_suite", "issue_comment", "pull_request"})
PERMISSION_RANK = {"read": 1, "write": 2, "admin": 3}
DELIVERIES_INSPECTED = 50
REDELIVERY_POLL_SECONDS = 2.0

OK = "ok"
WARN = "warn"
FAIL = "FAIL"


@dataclass
class AppReport:
    """Findings for one App, as `(level, message)` pairs in the order they were checked."""

    login: str
    findings: list[tuple[str, str]] = field(default_factory=list)

    def add(self, level: str, message: str) -> None:
        self.findings.append((level, message))

    @property
    def failed(self) -> bool:
        return any(level == FAIL for level, _ in self.findings)


def check_github_apps(
    apps: list[GitHubAppConfig],
    *,
    webhook_url: str | None = None,
    redeliver_ping: bool = False,
    wait_seconds: float = 20.0,
    sleep: Callable[[float], None] = time.sleep,
) -> list[AppReport]:
    """One report per App. The redelivery result is awaited for at most `wait_seconds` (the `--wait-seconds` option)."""
    return [
        AppCheck(container.github_app(config), webhook_url=webhook_url, sleep=sleep).run(
            redeliver_ping=redeliver_ping, wait_seconds=wait_seconds
        )
        for config in apps
    ]


class AppCheck:
    def __init__(
        self, api: GithubAppApi, *, webhook_url: str | None = None, sleep: Callable[[float], None] = time.sleep
    ) -> None:
        self.api = api
        self.config = api.config
        self.webhook_url = webhook_url
        self.sleep = sleep
        self.report = AppReport(api.config.login)

    def run(self, *, redeliver_ping: bool = False, wait_seconds: float = 20.0) -> AppReport:
        app = self._authenticate()
        if app is None:
            return self.report
        self._check_app_settings(app)
        try:
            installation = self._check_installation(app)
            if installation is not None:
                self._check_repository(installation)
            self._check_webhook()
            deliveries = self._check_deliveries()
            if redeliver_ping:
                self._redeliver_ping(deliveries, wait_seconds)
        except GithubError as error:
            self.report.add(FAIL, f"GitHub API: {error}")
        except httpx.HTTPError as error:
            self.report.add(FAIL, f"GitHub API: {type(error).__name__}: {error}")
        return self.report

    # ----- authentication and App settings
    def _authenticate(self) -> dict[str, Any] | None:
        try:
            app = self.api.app()
        except FileNotFoundError:
            self.report.add(FAIL, f"private key not found: {self.config.cert}")
            return None
        except GithubError as error:
            hint = " (wrong App ID or private key, or the key was revoked)" if error.status == 401 else ""
            self.report.add(FAIL, f"authentication: GitHub answered {error.status}{hint}")
            return None
        except Exception as error:
            self.report.add(FAIL, f"authentication: {type(error).__name__}: {error}")
            return None
        owner = (app.get("owner") or {}).get("login", "?")
        self.report.add(OK, f"authenticated as {app.get('slug')} (owner {owner})")
        return app

    def _check_app_settings(self, app: dict[str, Any]) -> None:
        missing = _missing_permissions(app.get("permissions") or {})
        if missing:
            self.report.add(FAIL, f"App permissions missing: {missing} (edit {_app_settings_url(app)}/permissions)")
        else:
            self.report.add(OK, "App permissions")
        events = set(app.get("events") or [])
        if not_subscribed := sorted(REQUIRED_EVENTS - events):
            self.report.add(FAIL, f"events not subscribed: {', '.join(not_subscribed)}")
        else:
            self.report.add(OK, "subscribed events")
        if extra := sorted(events - REQUIRED_EVENTS):
            self.report.add(WARN, f"events subscribed but not handled (answered 401): {', '.join(extra)}")

    # ----- installation and repository
    def _check_installation(self, app: dict[str, Any]) -> dict[str, Any] | None:
        installations = self.api.installations()
        if not installations:
            self.report.add(FAIL, f"not installed: install it at {app.get('html_url')}/installations/new")
            return None
        first = installations[0]
        if len(installations) > 1:
            accounts = ", ".join(_account(i) for i in installations)
            self.report.add(
                FAIL,
                f"{len(installations)} installations ({accounts}): the service only uses the first, {_account(first)}",
            )
        else:
            self.report.add(OK, f"installed on {_account(first)}")
        if first.get("suspended_at"):
            self.report.add(FAIL, f"installation on {_account(first)} is suspended")
        if missing := _missing_permissions(first.get("permissions") or {}):
            self.report.add(
                FAIL,
                f"installation has not accepted the permissions {missing}: an owner of {_account(first)} must approve "
                f"them at {first.get('html_url')}",
            )
        if first.get("repository_selection") == "all":
            self.report.add(WARN, "installed on all repositories of the account (doc/13 recommends selected ones)")
        return first

    def _check_repository(self, installation: dict[str, Any]) -> None:
        if not self.config.repo:
            self.report.add(WARN, "no `repo` configured for this App: it is only used as a fallback")
            return
        repositories = {name.lower() for name in self.api.installation_repositories()}
        if self.config.repo.lower() in repositories:
            self.report.add(OK, f"repository {self.config.repo} accessible")
        else:
            self.report.add(
                FAIL, f"repository {self.config.repo} not accessible: add it at {installation.get('html_url')}"
            )

    # ----- webhook
    def _check_webhook(self) -> None:
        hook = self.api.hook_config()
        url = str(hook.get("url") or "")
        if not url:
            self.report.add(FAIL, "webhook URL is empty")
        elif self.webhook_url and url.rstrip("/") != self.webhook_url.rstrip("/"):
            self.report.add(FAIL, f"webhook URL is {url}, expected {self.webhook_url}")
        else:
            self.report.add(OK, f"webhook URL {url}")
        if hook.get("content_type") != "json":
            self.report.add(FAIL, f"webhook content type is {hook.get('content_type')!r}, expected 'json'")
        if str(hook.get("insecure_ssl", "0")) != "0":
            self.report.add(WARN, "webhook SSL verification is disabled")

    def _check_deliveries(self) -> list[dict[str, Any]]:
        deliveries = self.api.hook_deliveries(DELIVERIES_INSPECTED)
        if not deliveries:
            self.report.add(WARN, "no webhook deliveries yet")
            return deliveries
        last = deliveries[0]
        failed = [d for d in deliveries if not _delivered(d)]
        level = OK if _delivered(last) else WARN
        self.report.add(level, f"last delivery: {_describe(last)}")
        if failed:
            self.report.add(
                WARN, f"{len(failed)} of the last {len(deliveries)} deliveries failed; latest: {_describe(failed[0])}"
            )
        return deliveries

    def _redeliver_ping(self, deliveries: list[dict[str, Any]], wait_seconds: float) -> None:
        ping = next((d for d in deliveries if d.get("event") == "ping"), None)
        if ping is None:
            self.report.add(FAIL, "no ping delivery to redeliver among the most recent deliveries")
            return
        self.api.redeliver(int(ping["id"]))
        waited = 0.0
        while waited < wait_seconds:
            self.sleep(REDELIVERY_POLL_SECONDS)
            waited += REDELIVERY_POLL_SECONDS
            attempt = next(
                (
                    d
                    for d in self.api.hook_deliveries(DELIVERIES_INSPECTED)
                    if d.get("guid") == ping.get("guid") and d.get("redelivery") and d.get("id") != ping.get("id")
                ),
                None,
            )
            if attempt is not None:
                self.report.add(OK if _delivered(attempt) else FAIL, f"ping redelivered: {_describe(attempt)}")
                return
        self.report.add(WARN, f"ping redelivery requested; no result after {wait_seconds:g} s (see Recent Deliveries)")


def _missing_permissions(granted: dict[str, str]) -> str:
    missing = [
        f"{name}:{level}"
        for name, level in REQUIRED_PERMISSIONS.items()
        if PERMISSION_RANK.get(granted.get(name, ""), 0) < PERMISSION_RANK[level]
    ]
    return ", ".join(missing)


def _app_settings_url(app: dict[str, Any]) -> str:
    owner = (app.get("owner") or {}).get("login", "")
    return f"https://github.com/organizations/{owner}/settings/apps/{app.get('slug')}"


def _account(installation: dict[str, Any]) -> str:
    return str((installation.get("account") or {}).get("login", installation.get("id")))


def _delivered(delivery: dict[str, Any]) -> bool:
    return 200 <= int(delivery.get("status_code") or 0) < 300


def _describe(delivery: dict[str, Any]) -> str:
    return (
        f"{delivery.get('event')} at {delivery.get('delivered_at')} -> "
        f"{delivery.get('status_code')} {delivery.get('status') or ''}".rstrip()
    )
