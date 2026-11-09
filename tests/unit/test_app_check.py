#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_app_check.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""`check-github`: verification of the GitHub App configuration through the GitHub API."""

from __future__ import annotations

import json
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import httpx
import pytest
import respx

from netdef_ci import container
from netdef_ci.cli.main import main
from netdef_ci.clients.github import GithubAppApi
from netdef_ci.config import GitHubAppConfig
from netdef_ci.services.app_check import FAIL, OK, WARN, AppCheck

API = "https://api.github.com"
PERMISSIONS = {
    "checks": "write",
    "pull_requests": "write",
    "issues": "write",
    "metadata": "read",
    "discussions": "write",
}
INSTALLATION = {
    "id": 7,
    "account": {"login": "org"},
    "permissions": PERMISSIONS,
    "repository_selection": "selected",
    "suspended_at": None,
    "html_url": "https://github.com/organizations/org/settings/installations/7",
}
PING = {"id": 100, "guid": "g-ping", "event": "ping", "status_code": 502, "status": "Bad Gateway", "redelivery": False}


def delivery(**fields: object) -> dict[str, object]:
    base = {"id": 200, "guid": "g-pr", "event": "pull_request", "status_code": 202, "status": "OK", "redelivery": False}
    base["delivered_at"] = "2026-11-06T10:00:00Z"
    return {**base, **fields}


@pytest.fixture
def api() -> Iterator[respx.MockRouter]:
    """A healthy App; tests replace single routes with `api.routes["<name>"]`."""
    container.reset()
    expires = (datetime.now(UTC) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with respx.mock(assert_all_called=False) as router:
        router.get(f"{API}/app", name="app").respond(
            200,
            json={
                "slug": "netdef-ci",
                "owner": {"login": "org"},
                "html_url": "https://github.com/apps/netdef-ci",
                "permissions": PERMISSIONS,
                "events": ["check_run", "check_suite", "issue_comment", "pull_request"],
            },
        )
        router.get(f"{API}/app/installations", name="installations").respond(200, json=[INSTALLATION])
        router.post(f"{API}/app/installations/7/access_tokens").respond(
            201, json={"token": "ghs_tokentoken", "expires_at": expires}
        )
        router.get(f"{API}/installation/repositories", name="repositories").respond(
            200, json={"repositories": [{"full_name": "Org/Repo"}]}
        )
        router.get(f"{API}/app/hook/config", name="hook").respond(
            200, json={"url": "https://ci.example.org/githubcheck", "content_type": "json", "insecure_ssl": "0"}
        )
        router.get(f"{API}/app/hook/deliveries", name="deliveries").respond(200, json=[delivery(), PING])
        router.post(f"{API}/app/hook/deliveries/100/attempts", name="redeliver").respond(202, json={})
        yield router
    container.reset()


def run(settings, sleeps: list[float] | None = None, **options: object):
    config = settings.github_apps()[0]
    check = AppCheck(
        GithubAppApi(config, settings, client=httpx.Client()),
        webhook_url=options.pop("webhook_url", None),  # type: ignore[arg-type]
        sleep=sleeps.append if sleeps is not None else (lambda _s: None),
    )
    return check.run(**options)  # type: ignore[arg-type]


def levels(report) -> dict[str, str]:
    return {message: level for level, message in report.findings}


def test_healthy_app_passes_every_check_and_the_command_exits_0(api, capsys) -> None:
    assert main(["check-github", "--webhook-url", "https://ci.example.org/githubcheck/"]) == 0
    out = capsys.readouterr().out
    assert "GitHub App 12345:" in out
    assert "ok   authenticated as netdef-ci (owner org)" in out
    assert "installed on org" in out and "repository org/repo accessible" in out
    assert "webhook URL https://ci.example.org/githubcheck" in out
    assert "warn" in out  # the old failed ping is reported, but it is not a failure
    assert out.rstrip().endswith("GitHub Apps OK")
    assert api.routes["redeliver"].call_count == 0  # read-only without --redeliver-ping


def test_command_without_configured_apps_fails(monkeypatch, settings, capsys) -> None:
    monkeypatch.setattr(type(settings), "github_apps", lambda _self: [])
    assert main(["check-github"]) == 1
    assert "no GitHub App configured" in capsys.readouterr().err


def test_rejected_jwt_stops_with_a_hint(api, settings) -> None:
    api.routes["app"].respond(401, json={"message": "A JSON web token could not be decoded"})
    report = run(settings)
    assert report.failed
    assert report.findings == [
        (FAIL, "authentication: GitHub answered 401 (wrong App ID or private key, or the key was revoked)")
    ]
    assert api.routes["installations"].call_count == 0


def test_missing_private_key_is_reported(settings) -> None:
    api = GithubAppApi(GitHubAppConfig("1", "/nonexistent/app.pem"), settings, client=httpx.Client())
    report = AppCheck(api).run()
    assert report.findings == [(FAIL, "private key not found: /nonexistent/app.pem")]


def test_transport_error_on_authentication_is_reported(api, settings) -> None:
    api.routes["app"].mock(side_effect=httpx.ConnectError("refused"))
    report = run(settings)
    assert report.failed and "ConnectError" in report.findings[0][1]


def test_missing_permissions_and_events_fail_and_extra_events_warn(api, settings) -> None:
    app = json.loads(api.routes["app"].return_value.content)
    app["permissions"] = {**PERMISSIONS, "checks": "read"}
    app["events"] = ["check_run", "pull_request", "discussion_comment"]
    api.routes["app"].respond(200, json=app)
    found = levels(run(settings))
    assert (
        found[
            "App permissions missing: checks:write (edit https://github.com/organizations/org/settings/apps/netdef-ci/permissions)"
        ]
        == FAIL
    )
    assert found["events not subscribed: check_suite, issue_comment"] == FAIL
    assert found["events subscribed but not handled (answered 401): discussion_comment"] == WARN


def test_app_without_installation_points_to_the_install_page(api, settings) -> None:
    api.routes["installations"].respond(200, json=[])
    found = levels(run(settings))
    assert found["not installed: install it at https://github.com/apps/netdef-ci/installations/new"] == FAIL
    assert api.routes["repositories"].call_count == 0


def test_more_than_one_installation_fails_because_only_the_first_is_used(api, settings) -> None:
    other = {**INSTALLATION, "id": 8, "account": {"login": "other-org"}}
    api.routes["installations"].respond(200, json=[INSTALLATION, other])
    found = levels(run(settings))
    assert found["2 installations (org, other-org): the service only uses the first, org"] == FAIL


@pytest.mark.parametrize(
    ("installation", "message", "level"),
    [
        (
            {"permissions": {**PERMISSIONS, "issues": "read"}},
            "installation has not accepted the permissions issues:write: an owner of org must approve them at "
            "https://github.com/organizations/org/settings/installations/7",
            FAIL,
        ),
        ({"suspended_at": "2026-11-01T00:00:00Z"}, "installation on org is suspended", FAIL),
        (
            {"repository_selection": "all"},
            "installed on all repositories of the account (doc/13 recommends selected ones)",
            WARN,
        ),
    ],
)
def test_installation_state_is_checked(api, settings, installation, message, level) -> None:
    api.routes["installations"].respond(200, json=[{**INSTALLATION, **installation}])
    assert levels(run(settings))[message] == level


def test_repository_outside_the_installation_fails(api, settings) -> None:
    api.routes["repositories"].respond(200, json={"repositories": [{"full_name": "org/other"}]})
    found = levels(run(settings))
    assert (
        found[
            "repository org/repo not accessible: add it at https://github.com/organizations/org/settings/installations/7"
        ]
        == FAIL
    )


def test_repository_list_is_paginated(api, settings) -> None:
    page1 = {"repositories": [{"full_name": f"org/r{i}"} for i in range(100)]}
    api.routes["repositories"].side_effect = [
        httpx.Response(200, json=page1),
        httpx.Response(200, json={"repositories": [{"full_name": "org/repo"}]}),
    ]
    assert levels(run(settings))["repository org/repo accessible"] == OK
    assert api.routes["repositories"].call_count == 2


def test_app_without_repo_only_warns(api, settings) -> None:
    config = GitHubAppConfig("12345", settings.github_apps()[0].cert)
    report = AppCheck(GithubAppApi(config, settings, client=httpx.Client())).run()
    assert levels(report)["no `repo` configured for this App: it is only used as a fallback"] == WARN
    assert not report.failed


@pytest.mark.parametrize(
    ("hook", "expected", "message", "level"),
    [
        ({"url": ""}, None, "webhook URL is empty", FAIL),
        (
            {},
            "https://other.example.org/githubcheck",
            "webhook URL is https://ci.example.org/githubcheck, expected https://other.example.org/githubcheck",
            FAIL,
        ),
        ({"content_type": "form"}, None, "webhook content type is 'form', expected 'json'", FAIL),
        ({"insecure_ssl": "1"}, None, "webhook SSL verification is disabled", WARN),
    ],
)
def test_webhook_configuration_is_checked(api, settings, hook, expected, message, level) -> None:
    base = {"url": "https://ci.example.org/githubcheck", "content_type": "json", "insecure_ssl": "0"}
    api.routes["hook"].respond(200, json={**base, **hook})
    assert levels(run(settings, webhook_url=expected))[message] == level


def test_deliveries_report_the_last_one_and_the_failures(api, settings) -> None:
    found = levels(run(settings))
    assert found["last delivery: pull_request at 2026-11-06T10:00:00Z -> 202 OK"] == OK
    assert found["1 of the last 2 deliveries failed; latest: ping at None -> 502 Bad Gateway"] == WARN


def test_no_deliveries_only_warns(api, settings) -> None:
    api.routes["deliveries"].respond(200, json=[])
    report = run(settings)
    assert levels(report)["no webhook deliveries yet"] == WARN and not report.failed


def test_api_error_after_authentication_is_reported(api, settings) -> None:
    api.routes["hook"].respond(500, text="boom")
    report = run(settings)
    assert report.failed and report.findings[-1][1].startswith("GitHub API: GitHub API error 500")


def test_redeliver_ping_waits_for_the_new_attempt(api, settings) -> None:
    attempt = {**PING, "id": 101, "redelivery": True, "status_code": 200, "status": "OK"}
    api.routes["deliveries"].side_effect = [
        httpx.Response(200, json=[delivery(), PING]),
        httpx.Response(200, json=[delivery(), PING]),
        httpx.Response(200, json=[attempt, delivery(), PING]),
    ]
    sleeps: list[float] = []
    report = run(settings, sleeps, redeliver_ping=True, wait_seconds=10)
    assert api.routes["redeliver"].call_count == 1
    assert sleeps == [2.0, 2.0]
    assert report.findings[-1] == (OK, "ping redelivered: ping at None -> 200 OK")
    assert not report.failed


def test_redelivered_ping_that_fails_fails_the_check(api, settings) -> None:
    attempt = {**PING, "id": 101, "redelivery": True, "status_code": 401, "status": "Invalid HTTP Response: 401"}
    api.routes["deliveries"].side_effect = [
        httpx.Response(200, json=[delivery(), PING]),
        httpx.Response(200, json=[attempt, PING]),
    ]
    report = run(settings, redeliver_ping=True)
    assert report.findings[-1] == (FAIL, "ping redelivered: ping at None -> 401 Invalid HTTP Response: 401")


def test_redelivery_without_result_warns_after_the_wait(api, settings) -> None:
    sleeps: list[float] = []
    report = run(settings, sleeps, redeliver_ping=True, wait_seconds=5)
    assert sleeps == [2.0, 2.0, 2.0]
    assert report.findings[-1] == (WARN, "ping redelivery requested; no result after 5 s (see Recent Deliveries)")


def test_redeliver_without_a_ping_fails(api, settings) -> None:
    api.routes["deliveries"].respond(200, json=[delivery()])
    report = run(settings, redeliver_ping=True)
    assert report.findings[-1] == (FAIL, "no ping delivery to redeliver among the most recent deliveries")
    assert api.routes["redeliver"].call_count == 0


def test_command_with_problems_exits_1(api, capsys) -> None:
    api.routes["installations"].respond(200, json=[])
    assert main(["check-github", "--redeliver-ping", "--wait-seconds", "0"]) == 1
    assert capsys.readouterr().out.rstrip().endswith("1 GitHub App(s) with problems")


def test_transport_error_after_authentication_is_reported(api, settings) -> None:
    api.routes["deliveries"].mock(side_effect=httpx.ReadTimeout("slow"))
    report = run(settings)
    assert report.failed and report.findings[-1] == (FAIL, "GitHub API: ReadTimeout: slow")
