#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_http_api.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""HTTP contract of the service."""

from __future__ import annotations

import json
import time
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from netdef_ci.enums import Status
from netdef_ci.models import Job, PullRequest, WebhookDelivery
from tests import factories as f
from tests import payloads


# ---------------------------------------------------------------------------- operational endpoints
def test_ping(api) -> None:
    response = api.http.get("/ping")
    assert (response.status_code, response.text) == (200, "Pong")


def test_double_leading_slash_from_a_proxy_is_normalized(api) -> None:
    # nginx `location /prefix { proxy_pass http://app/; }` turns /prefix/ping into //ping
    assert api.http.get("http://testserver//ping").text == "Pong"
    assert api.http.get("http://testserver//healthz").status_code == 200
    assert api.github("ping", {}, path="http://testserver//some/hook").text == "PONG!"


def test_health_and_readiness(api) -> None:
    assert api.http.get("/healthz").json()["status"] == "ok"
    ready = api.http.get("/readyz")
    assert ready.status_code == 200 and ready.json() == {"status": "ready", "database": "ok"}


def test_readiness_fails_when_the_database_is_down(api, monkeypatch) -> None:
    from netdef_ci.web import app as app_module

    def broken():
        raise ConnectionError("db down")

    monkeypatch.setattr(app_module, "session_scope", broken)
    response = api.http.get("/readyz")
    assert response.status_code == 503 and response.json()["status"] == "unavailable"


def test_telemetry_is_json(api) -> None:
    body = api.http.get("/telemetry").json()
    assert {"version", "uptime_seconds"} <= set(body)


def test_metrics_require_basic_auth(api) -> None:
    assert api.http.get("/metrics").status_code == 401
    assert api.http.get("/metrics", headers={"Authorization": "Bearer x"}).status_code == 401
    assert api.http.get("/metrics", headers=api.basic("metrics", "wrong")).status_code == 401
    ok = api.http.get("/metrics", headers=api.basic("metrics", "metricspass"))
    assert ok.status_code == 200 and ok.headers["content-type"].startswith("text/plain; version=0.0.4")


def test_metrics_expose_the_expected_metric_names(api) -> None:
    from netdef_ci import metrics

    metrics.track_bamboo("probe", lambda: None)
    api.http.get("/ping")
    api.github("ping", {})
    text = api.http.get("/metrics", headers=api.basic("metrics", "metricspass")).text
    for name in (
        'http_requests_total{method="GET",path="/ping",status="200"}',
        'github_webhook_events_total{event="ping",result="processed"}',
        "http_request_duration_seconds_bucket",
        "delayed_jobs_pending",
        "delayed_jobs_scheduled",
        "ci_jobs_total",
        "ci_stages_total",
        "activerecord_connection_pool_size",
        "activerecord_queries_total",
        "http_server_requests_total",
        "http_server_request_duration_seconds",
        "puma_workers_total",
        "puma_booted_workers",
        "puma_running_threads",
        "puma_pool_capacity",
        "puma_max_threads",
        "puma_backlog",
        "activerecord_connection_pool_waiting",
        "bamboo_api_requests_total",
    ):
        assert name in text, name


# ---------------------------------------------------------------------------- /update/status authentication
def test_update_status_without_signature_is_404(api) -> None:
    response = api.http.post("/update/status", content=b"{}", headers={"Accept": "application/json"})
    assert (response.status_code, response.text) == (404, "Signature not found")


def test_update_status_with_wrong_signature_is_401(api) -> None:
    response = api.http.post("/update/status", content=b"{}", headers={"Signature": "1234"})
    assert (response.status_code, response.text) == (401, "Signatures didn't match!")


def test_update_status_with_empty_body_is_401(api) -> None:
    assert api.http.post("/update/status", content=b"", headers={"Signature": "x"}).status_code == 401


def test_signature_must_cover_the_exact_raw_bytes(api) -> None:
    body = b'{"status": "success",  "bamboo_ref": "X-1"}'
    headers = api.signed(b'{"status":"success","bamboo_ref":"X-1"}', "Signature")  # same JSON, different bytes
    assert api.http.post("/update/status", content=body, headers=headers).status_code == 401


def test_both_signature_header_names_are_accepted(api) -> None:
    for header in ("Signature", "X-Hub-Signature-256"):
        assert (
            api.status({"status": "success", "bamboo_ref": "X-1"}, header).status_code == 404
        )  # authenticated, job unknown


def test_update_status_routes_by_status(api, session) -> None:
    w = f.World(session)
    started = api.status({"status": "in_progress", "bamboo_ref": w.build_job.job_ref})
    assert (started.status_code, started.text) == (200, "Success")
    assert started.headers["content-type"].startswith("application/json")
    ignored = api.status({"status": "success", "bamboo_ref": w.tests_job.job_ref})
    assert ignored.status_code == 304 and ignored.content == b""
    assert api.status({"status": "success", "bamboo_ref": "NOPE"}).text == "CI JOB not found"


def test_finished_status_schedules_the_reconciliation_on_the_pr_queue(api, session, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Tests", "finished": False}
    response = api.status({"status": "finished", "bamboo_ref": "PROJ-PLAN-77"})
    assert (response.status_code, response.text) == (200, "Finished scheduled")
    job = session.scalars(select(Job).where(Job.handler == "finished_execution")).one()
    assert job.queue == str(w.pr.github_pr_id % 10) and job.args == [
        {"status": "finished", "bamboo_ref": "PROJ-PLAN-77"}
    ]
    assert api.status({"status": "finished", "bamboo_ref": "NOPE-1"}).status_code == 404


def test_retry_webhook_only_schedules_the_retry(api, session, bamboo) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.FAILURE))
    response = api.github("check_run", payloads.check_run(int(w.tests_stage.check_ref)))
    assert (response.status_code, response.text) == (200, "Retry scheduled")
    job = session.scalars(select(Job).where(Job.handler == "retry_execution")).one()
    assert (job.queue, job.max_attempts, job.args[0]) == ("retry_execution", 1, "command")
    assert bamboo.restarted == [] and bamboo.stopped == []


def test_unexpected_errors_are_500_json_without_details(api, monkeypatch) -> None:
    from netdef_ci.web import webhooks

    def explode(*_a, **_k):
        raise RuntimeError("secret internals")

    monkeypatch.setattr(webhooks, "UpdateStatus", explode)
    response = api.status({"status": "success", "bamboo_ref": "X"})
    assert response.status_code == 500 and response.json() == {"error": "Internal Server Error"}
    metrics = api.http.get("/metrics", headers=api.basic("metrics", "metricspass")).text
    assert 'app_exceptions_total{class="RuntimeError",handler="update"}' in metrics


def test_invalid_json_after_authentication_is_400(api) -> None:
    body = b"{not json"
    response = api.http.post("/update/status", content=body, headers=api.signed(body, "Signature"))
    assert response.status_code == 400


# ---------------------------------------------------------------------------- GitHub webhooks
def test_webhook_requires_a_valid_signature(api) -> None:
    assert api.http.post("/", content=b"{}", headers={"X-GitHub-Event": "ping"}).status_code == 404
    assert (
        api.http.post(
            "/", content=b"{}", headers={"X-GitHub-Event": "ping", "X-Hub-Signature-256": "sha256=00"}
        ).status_code
        == 401
    )


def test_webhook_ping(api) -> None:
    response = api.github("ping", {})
    assert (response.status_code, response.text) == (200, "PONG!")
    assert response.headers["content-type"].startswith("text/plain")


def test_any_path_reaches_the_webhook_handler(api) -> None:
    assert api.github("ping", {}, path="/some/hook/path").text == "PONG!"


def test_unknown_and_missing_events(api) -> None:
    assert api.github("potato", {"a": 1}).status_code == 401
    assert api.github("potato", {"a": 1}).text == "Invalid request (4)"
    assert api.github(None, {"a": 1}).status_code == 400


def test_installation_event(api) -> None:
    response = api.github("installation", {"action": "created"})
    assert (response.status_code, response.text) == (202, "Updated")


def test_pull_request_event_schedules_executions(api, session) -> None:
    f.plan(session)
    response = api.github("pull_request", payloads.pull_request())
    assert (response.status_code, response.text) == (200, "Scheduled Plan Runs")
    assert session.scalars(select(Job)).one().handler == "create_execution_by_plan"
    assert api.github("pull_request", {"x": 1}).status_code == 405
    assert api.github("pull_request", payloads.pull_request(action="closed")).status_code == 405


def test_pull_request_without_plans_is_422(api, session) -> None:
    assert api.github("pull_request", payloads.pull_request()).status_code == 422
    assert session.scalars(select(PullRequest)).one()


def test_check_run_event(api, session) -> None:
    assert api.github("check_run", {"x": 1, "action": "created"}).text == "OK"
    assert api.github("check_run", {"x": 1, "action": "rerequested"}).status_code == 404
    w = f.World(session, statuses=(Status.SUCCESS, Status.QUEUED))
    response = api.github("check_run", payloads.check_run(int(w.tests_stage.check_ref)))
    assert (response.status_code, response.text) == (406, "Already enqueued this execution")


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        ("just talking", (200, "Just a comment")),
        ("CI:RETRY please", (404, "Stage not found")),
        ("ci:rerun", (404, "Pull Request not found")),
    ],
)
def test_issue_comment_routing(api, body, expected) -> None:
    response = api.github("issue_comment", payloads.issue_comment(body))
    assert (response.status_code, response.text) == expected


def test_issue_comment_without_comment_is_404(api) -> None:
    assert api.github("issue_comment", {"action": "created"}).status_code == 404
    assert api.github("issue_comment", {"comment": None}).text == "Action not found"


def test_retry_wins_when_both_commands_are_present(api, session) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    response = api.github("issue_comment", payloads.issue_comment("ci:rerun ci:retry", number=w.pr.github_pr_id))
    assert response.text == "Stage not found"  # handled by the retry flow


def test_check_suite_event(api, session) -> None:
    assert api.github("check_suite", {"action": "completed"}).text == "OK"
    assert api.github("check_suite", {}).text == "OK"
    assert api.github("check_suite", payloads.check_suite("f" * 40)).status_code == 404
    w = f.World(session)
    ok = api.github("check_suite", payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id))
    assert (ok.status_code, ok.text) == (200, "Scheduled Plan Runs")


def test_duplicate_deliveries_are_ignored_only_when_enabled(api, session, settings, monkeypatch) -> None:
    f.plan(session)
    headers = {"X-GitHub-Delivery": "abc-123"}
    api.github("pull_request", payloads.pull_request(), **headers)
    api.github("pull_request", payloads.pull_request(), **headers)
    assert len(session.scalars(select(Job)).all()) == 2  # default: no de-duplication
    monkeypatch.setattr(settings, "webhook_dedupe_ttl_seconds", 600)
    session.query(Job).delete()
    session.commit()
    first = api.github("pull_request", payloads.pull_request(), **{"X-GitHub-Delivery": "dup-1"})
    second = api.github("pull_request", payloads.pull_request(), **{"X-GitHub-Delivery": "dup-1"})
    assert first.text == "Scheduled Plan Runs" and (second.status_code, second.text) == (
        200,
        "Duplicate delivery ignored",
    )
    assert len(session.scalars(select(Job)).all()) == 1
    assert session.scalars(select(WebhookDelivery)).one().delivery_id == "dup-1"


def test_a_failed_delivery_can_be_redelivered(api, session, settings, monkeypatch) -> None:
    from netdef_ci.web import webhooks

    monkeypatch.setattr(settings, "webhook_dedupe_ttl_seconds", 600)
    original = webhooks.dispatch

    def explode(*_a, **_k):
        raise RuntimeError("boom")

    monkeypatch.setattr(webhooks, "dispatch", explode)
    assert api.github("ping", {}, **{"X-GitHub-Delivery": "redo-1"}).status_code == 500
    assert session.scalars(select(WebhookDelivery)).all() == []
    monkeypatch.setattr(webhooks, "dispatch", original)
    assert api.github("ping", {}, **{"X-GitHub-Delivery": "redo-1"}).text == "PONG!"
    assert api.github("ping", {}, **{"X-GitHub-Delivery": "redo-1"}).text == "Duplicate delivery ignored"


def test_comment_commands_older_than_the_dedupe_window_are_refused(api, settings, monkeypatch) -> None:
    old = payloads.issue_comment("ci:rerun")
    old["comment"]["created_at"] = "2020-01-01T00:00:00Z"
    # Without de-duplication there is no replay window: the command is routed as before.
    assert api.github("issue_comment", old).text == "Pull Request not found"
    monkeypatch.setattr(settings, "webhook_dedupe_ttl_seconds", 600)
    response = api.github("issue_comment", old)
    assert (response.status_code, response.text) == (422, "Stale comment ignored")
    fresh = payloads.issue_comment("ci:retry")
    fresh["comment"]["created_at"] = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    assert api.github("issue_comment", fresh).text == "Stage not found"
    old["comment"]["body"] = "just talking"
    assert api.github("issue_comment", old).text == "Just a comment"


def test_callback_timestamp_is_only_required_when_configured(api, settings, monkeypatch) -> None:
    assert api.status({"status": "success", "bamboo_ref": "X-1"}).text == "CI JOB not found"
    monkeypatch.setattr(settings, "bamboo_callback_max_age_seconds", 300)
    for stamp in (None, "now", True, time.time() - 301, time.time() + 301):
        payload = {"status": "success", "bamboo_ref": "X-1", **({} if stamp is None else {"timestamp": stamp})}
        response = api.status(payload)
        assert (response.status_code, response.text) == (401, "Stale or missing timestamp"), stamp
    assert api.status({"status": "success", "bamboo_ref": "X-1", "timestamp": int(time.time())}).status_code == 404


def test_a_replayed_callback_is_ignored(api, session, settings, monkeypatch) -> None:
    monkeypatch.setattr(settings, "bamboo_callback_max_age_seconds", 300)
    w = f.World(session)
    payload = {"status": "in_progress", "bamboo_ref": w.build_job.job_ref, "timestamp": int(time.time())}
    assert api.status(payload).text == "Success"
    assert api.status(payload).text == "Duplicate callback ignored"
    row = session.scalars(select(WebhookDelivery)).one()
    assert row.event == "bamboo_callback" and row.delivery_id.startswith("bamboo:")


def test_a_failed_callback_can_be_sent_again(api, settings, monkeypatch) -> None:
    from netdef_ci.web import webhooks

    monkeypatch.setattr(settings, "bamboo_callback_max_age_seconds", 300)
    original = webhooks.UpdateStatus

    def explode(*_a, **_k):
        raise RuntimeError("boom")

    payload = {"status": "success", "bamboo_ref": "X-1", "timestamp": int(time.time())}
    monkeypatch.setattr(webhooks, "UpdateStatus", explode)
    assert api.status(payload).status_code == 500
    monkeypatch.setattr(webhooks, "UpdateStatus", original)
    assert api.status(payload).text == "CI JOB not found"


def test_github_and_callback_records_expire_independently(api, session, settings, monkeypatch) -> None:
    from netdef_ci.db import utcnow

    monkeypatch.setattr(settings, "bamboo_callback_max_age_seconds", 300)
    assert api.status({"status": "success", "bamboo_ref": "X-1", "timestamp": int(time.time())}).status_code == 404
    session.query(WebhookDelivery).update({"received_at": utcnow() - timedelta(seconds=400)})
    session.commit()
    monkeypatch.setattr(settings, "webhook_dedupe_ttl_seconds", 60)
    api.github("ping", {}, **{"X-GitHub-Delivery": "keep-callbacks"})  # GitHub cleanup: older than 60 s
    events = sorted(row.event for row in session.scalars(select(WebhookDelivery)))
    assert events == ["bamboo_callback", "ping"]  # the callback row lives for 2 x 300 s


# ---------------------------------------------------------------------------- Slack
def test_slack_requires_the_bot_credentials(api) -> None:
    payload = json.dumps({"rule": "notify", "target": 1, "notification": "all", "slack_user_id": "ABC"})
    assert api.http.post("/slack", content=payload, headers={"Authorization": ""}).status_code == 401
    assert api.http.post("/slack", content=payload, headers=api.basic("slackbot", "nope")).status_code == 401
    assert api.http.post("/slack", content=payload).status_code == 401


def test_slack_subscription_and_settings(api, session) -> None:
    auth = api.basic("slackbot", "slackpass")
    payload = json.dumps({"rule": "notify", "target": 1, "notification": "all", "slack_user_id": "ABC"})
    response = api.http.post("/slack", content=payload, headers=auth)
    assert (response.status_code, response.text) == (200, "Subscription created")
    settings = api.http.post("/slack/settings", content=json.dumps({"slack_user_id": "ABC"}), headers=auth)
    assert settings.status_code == 200 and "Pull Request" in settings.text
    assert api.http.post("/slack/settings", content=b"{}", headers={"Authorization": ""}).status_code == 401


def test_slack_running_prs(api, session) -> None:
    f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    auth = api.basic("slackbot", "slackpass")
    response = api.http.post("/slack", content=json.dumps({"event": {}, "github_user": "alice"}), headers=auth)
    assert response.status_code == 200 and "https://github.com/org/repo/pull/" in response.text
    empty = api.http.post("/slack", content=json.dumps({"event": {}, "github_user": "zed"}), headers=auth)
    assert empty.text == "No running PR"
