#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_github_client.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta

import httpx
import jwt
import pytest
import respx

from netdef_ci.clients import github as gh
from netdef_ci.clients.github import GithubAuthError, GithubCheck, GithubError
from netdef_ci.config import get_settings
from tests import factories as f

API = "https://api.github.com"


def expiry(minutes: int = 60) -> str:
    return (datetime.now(UTC) + timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


@pytest.fixture(autouse=True)
def fresh_registry():
    gh.reset_app_auth_registry()
    yield
    gh.reset_app_auth_registry()


@pytest.fixture
def suite(session):
    w = f.World(session)
    return w.suite


@pytest.fixture
def mock_api():
    with respx.mock(assert_all_called=False) as router:
        router.get(f"{API}/app/installations").respond(200, json=[{"id": 7}])
        router.post(f"{API}/app/installations/7/access_tokens", name="token").respond(
            201, json={"token": "ghs_tokentoken", "expires_at": expiry()}
        )
        yield router


def make(suite, sleeps: list[float] | None = None) -> GithubCheck:
    return GithubCheck(
        suite, get_settings(), client=httpx.Client(), sleep=(sleeps.append if sleeps is not None else (lambda _s: None))
    )


def test_app_jwt_is_rs256_with_10_minute_limit_and_issuer(suite, mock_api, rsa_key) -> None:
    check = make(suite)
    token = check._app_auth().app_jwt()
    claims = jwt.decode(token, rsa_key.public_key(), algorithms=["RS256"])
    assert claims["iss"] == "12345"
    assert claims["exp"] - claims["iat"] <= 600
    assert claims["iat"] <= time.time()


def test_authentication_waits_for_the_first_api_call(suite, mock_api) -> None:
    check = make(suite)
    assert mock_api["token"].call_count == 0  # building a client costs no HTTP call
    check._app_auth()
    assert mock_api["token"].call_count == 1


def test_installation_token_is_cached_and_renewed_before_expiry(suite, mock_api) -> None:
    make(suite)._app_auth()
    make(suite)._app_auth()  # second client: no new token request
    token_route = mock_api["token"]
    assert token_route.call_count == 1
    auth = make(suite)._app_auth()
    auth._expires_at = datetime.now(UTC) + timedelta(minutes=2)  # inside the 5 minute renewal margin
    auth.token()
    assert token_route.call_count == 2


def test_requests_use_installation_token_and_api_headers(suite, mock_api) -> None:
    route = mock_api.get(f"{API}/repos/org/repo/pulls/5").respond(200, json={"number": 5})
    assert make(suite).pull_request_info(5, "org/repo") == {"number": 5}
    sent = route.calls.last.request
    assert sent.headers["authorization"] == "Bearer ghs_tokentoken"
    assert sent.headers["x-github-api-version"] == "2022-11-28"


@pytest.fixture
def github_http_log(settings, monkeypatch, tmp_path):
    import logging

    monkeypatch.setattr(settings, "log_dir", str(tmp_path))
    logger = logging.getLogger("netdef_ci.github_http")
    monkeypatch.setattr(logger, "handlers", [])
    monkeypatch.setattr(logger, "propagate", True)

    def lines() -> list[str]:
        for handler in logger.handlers:
            handler.flush()
        return (tmp_path / "github_http.log").read_text().splitlines()

    return lines


def test_github_calls_are_logged_with_their_pull_request(suite, mock_api, github_http_log) -> None:
    pr = suite.pull_request.github_pr_id
    mock_api.get(f"{API}/repos/org/repo/pulls/5").respond(404)
    mock_api.get(f"{API}/repos/{suite.pull_request.repository}/check-runs/9").respond(200, json={"id": 9})
    github = make(suite)
    with pytest.raises(gh.GithubNotFound):
        github.pull_request_info(5, "org/repo")
    github.get_check_run(9)
    lines = github_http_log()
    assert lines[0].endswith(f"INFO [PR {pr}] GET {API}/app/installations -> 200")
    assert lines[1].endswith(f"INFO [PR {pr}] POST {API}/app/installations/7/access_tokens -> 201")
    assert lines[2].endswith(f"WARNING [PR 5] GET {API}/repos/org/repo/pulls/5 -> 404")
    assert lines[3].endswith(f"INFO [PR {pr}] GET {API}/repos/{suite.pull_request.repository}/check-runs/9 -> 200")
    assert "ghs_tokentoken" not in "".join(lines)


def test_github_calls_without_a_pull_request_are_logged_as_unknown(mock_api, github_http_log) -> None:
    mock_api.get(f"{API}/users/octocat").respond(200, json={"login": "octocat"})
    GithubCheck(None, get_settings(), client=httpx.Client(), sleep=lambda _s: None).fetch_username("octocat")
    assert github_http_log()[-1].endswith(f"INFO [PR -] GET {API}/users/octocat -> 200")


def test_create_check_run_posts_name_and_head_sha(suite, mock_api) -> None:
    route = mock_api.post(f"{API}/repos/org/repo/check-runs").respond(201, json={"id": 9, "name": "[CI] Build"})
    assert make(suite).create("[CI] Build")["id"] == 9
    import json

    assert json.loads(route.calls.last.request.content) == {"name": "[CI] Build", "head_sha": suite.commit_sha_ref}


def test_update_sends_status_and_output_only_when_present(suite, mock_api) -> None:
    import json

    route = mock_api.patch(f"{API}/repos/org/repo/check-runs/9").respond(200, json={"id": 9})
    check = make(suite)
    check.in_progress("9")
    assert json.loads(route.calls.last.request.content) == {"status": "in_progress"}
    check.queued(9, {"title": "t", "summary": "s"})
    assert json.loads(route.calls.last.request.content) == {
        "status": "queued",
        "output": {"title": "t", "summary": "s"},
    }


def test_summary_above_github_limit_is_truncated(suite, mock_api) -> None:
    import json

    route = mock_api.patch(f"{API}/repos/org/repo/check-runs/9").respond(200, json={"conclusion": "success"})
    make(suite).success(9, {"title": "t", "summary": "x" * 70_000})
    assert len(json.loads(route.calls.last.request.content)["output"]["summary"]) == 65_535


def test_completed_checks_conclusion_and_retries_when_not_found(suite, mock_api) -> None:
    sleeps: list[float] = []
    route = mock_api.patch(f"{API}/repos/org/repo/check-runs/9")
    route.side_effect = [
        httpx.Response(404, json={}),
        httpx.Response(200, json={"conclusion": "neutral"}),
        httpx.Response(200, json={"conclusion": "success"}),
    ]
    assert make(suite, sleeps).success(9)["conclusion"] == "success"
    assert sleeps == [1, 2]


def test_completed_gives_up_after_bounded_retries(suite, mock_api) -> None:
    sleeps: list[float] = []
    route = mock_api.patch(f"{API}/repos/org/repo/check-runs/9").respond(404, json={})
    assert make(suite, sleeps).failure(9) == {}
    assert route.call_count == 4 and sleeps == [1, 2, 4]  # no sleep after the last attempt


def test_completed_without_check_ref_is_a_noop(suite, mock_api) -> None:
    assert make(suite).success(None) is None


def test_rate_limit_is_retried_with_retry_after_and_is_bounded(suite, mock_api) -> None:
    sleeps: list[float] = []
    route = mock_api.get(f"{API}/repos/org/repo/pulls/5")
    route.side_effect = [
        httpx.Response(403, headers={"retry-after": "3"}, json={}),
        httpx.Response(200, json={"ok": 1}),
    ]
    assert make(suite, sleeps).pull_request_info(5, "org/repo") == {"ok": 1}
    assert 3.0 in sleeps
    route.side_effect = None
    route.respond(429, headers={"retry-after": "1"}, json={})
    sleeps.clear()
    with pytest.raises(GithubError):
        make(suite, sleeps).pull_request_info(5, "org/repo")
    assert route.call_count == 2 + 4  # two calls of the first scenario + first try and 3 bounded retries


def test_server_errors_are_retried_for_reads_but_not_for_creation(suite, mock_api) -> None:
    get = mock_api.get(f"{API}/repos/org/repo/pulls/5")
    get.side_effect = [httpx.Response(503), httpx.Response(200, json={"n": 1})]
    assert make(suite).pull_request_info(5, "org/repo") == {"n": 1}
    post = mock_api.post(f"{API}/repos/org/repo/check-runs").respond(502, json={})
    with pytest.raises(GithubError):
        make(suite).create("x")
    assert post.call_count == 1  # POST is not idempotent


def test_expired_token_is_renewed_once_on_401(suite, mock_api) -> None:
    token_route = mock_api["token"]
    route = mock_api.get(f"{API}/repos/org/repo/pulls/5")
    route.side_effect = [httpx.Response(401, json={}), httpx.Response(200, json={"n": 2})]
    assert make(suite).pull_request_info(5, "org/repo") == {"n": 2}
    assert token_route.call_count == 2


def test_authentication_fails_without_installation(suite) -> None:
    with respx.mock() as router:
        router.get(f"{API}/app/installations").respond(200, json=[])
        with pytest.raises(GithubAuthError):
            make(suite).pull_request_info(5, "org/repo")


def test_username_lookup_uses_id_or_login_and_swallows_errors(suite, mock_api) -> None:
    mock_api.get(f"{API}/user/55").respond(200, json={"login": "bob"})
    mock_api.get(f"{API}/users/bob").respond(200, json={"login": "bob"})
    mock_api.get(f"{API}/users/ghost").respond(404, json={})
    check = make(suite)
    assert check.fetch_username(55)["login"] == "bob"
    assert check.fetch_username("bob")["login"] == "bob"
    assert check.fetch_username("ghost") is None


def test_reactions_and_check_run_listing(suite, mock_api) -> None:
    import json

    up = mock_api.post(f"{API}/repos/org/repo/issues/comments/3/reactions").respond(201, json={})
    runs = mock_api.get(f"{API}/repos/org/repo/commits/abc/check-runs").respond(200, json={"check_runs": [{"id": 1}]})
    check = make(suite)
    check.comment_reaction_thumb_up("org/repo", 3)
    assert json.loads(up.calls.last.request.content) == {"content": "+1"}
    check.comment_reaction_rocket("org/repo", 3)
    assert json.loads(up.calls.last.request.content) == {"content": "rocket"}
    delete = mock_api.delete(f"{API}/repos/org/repo/issues/comments/3/reactions/55").respond(204)
    check.delete_comment_reaction("org/repo", 3, 55)
    assert delete.called
    assert check.check_runs_for_ref("org/repo", "abc", status="queued")["check_runs"] == [{"id": 1}]
    assert runs.calls.last.request.url.params["status"] == "queued"
    check.check_runs_for_ref("org/repo", "abc", status=None)
    assert "status" not in runs.calls.last.request.url.params  # every status in one listing


def test_signature_is_the_webhook_secret(suite, mock_api) -> None:
    assert make(suite).signature() == "test-secret"


def test_pull_requests_follow_every_page(suite, mock_api) -> None:
    route = mock_api.get(f"{API}/repos/org/repo/pulls")
    route.side_effect = [
        httpx.Response(200, json=[{"number": n} for n in range(100)]),
        httpx.Response(200, json=[{"number": 100}]),
    ]
    assert len(make(suite).pull_requests("org/repo")) == 101
    assert [call.request.url.params["page"] for call in route.calls] == ["1", "2"]
