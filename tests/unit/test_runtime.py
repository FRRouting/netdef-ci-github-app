#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_runtime.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Logging redaction, HTTP retry helper, process wiring and concurrency of the job queue."""

from __future__ import annotations

import logging
import threading
import time

import httpx
import pytest
import respx
from sqlalchemy import select

from netdef_ci import container
from netdef_ci.clients.http import MAX_RETRY_AFTER_SECONDS, request_with_retries, retry_after_seconds
from netdef_ci.jobs import queue
from netdef_ci.jobs.registry import HANDLERS, job_handler
from netdef_ci.logs import Log, redact
from netdef_ci.models import Job
from tests.conftest import IS_PG


# ---------------------------------------------------------------------------- redaction
@pytest.mark.parametrize(
    ("raw", "secret"),
    [
        ("Authorization: Bearer abc.def-123", "abc.def-123"),
        ("url?bamboo.variable.github_signature_secret=s3cr3t&x=1", "s3cr3t"),
        ("token ghs_abcdefghijklmnopqrstuvwxyz0123 used", "ghs_abcdefghijklmnopqrstuvwxyz0123"),
        ("{'password': 'hunter2'}", "hunter2"),
        ("X-Hub-Signature-256: sha256=" + "a1" * 32, "a1" * 32),
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----", "MIIB"),
    ],
)
def test_secrets_are_redacted(raw, secret) -> None:
    assert secret not in redact(raw)


def test_log_lines_are_redacted_before_reaching_handlers(caplog) -> None:
    from netdef_ci.logs import RedactingFilter

    record = logging.LogRecord("netdef_ci.x", logging.INFO, __file__, 1, "token=%s", ("topsecret",), None)
    RedactingFilter().filter(record)
    assert "topsecret" not in record.msg


def test_pr_logs_go_to_per_pull_request_files(tmp_path, monkeypatch, settings) -> None:
    from netdef_ci import logs

    monkeypatch.setattr(settings, "log_dir", str(tmp_path))
    monkeypatch.setattr(logs, "_file_handlers", {})
    logging.getLogger("netdef_ci.pr.321").handlers.clear()
    Log("component", 321).info("hello Bearer abc123")
    for handler in logs._file_handlers.values():
        handler.flush()
    content = (tmp_path / "pr321.log").read_text()
    assert "hello" in content and "abc123" not in content


# ---------------------------------------------------------------------------- HTTP helper
def test_retry_after_parsing_is_bounded() -> None:
    assert retry_after_seconds(httpx.Response(403, headers={"retry-after": "7"})) == 7
    assert retry_after_seconds(httpx.Response(429, headers={"retry-after": "9999"})) == MAX_RETRY_AFTER_SECONDS
    assert retry_after_seconds(httpx.Response(429)) == 5.0
    assert retry_after_seconds(httpx.Response(403, text="You have exceeded a secondary rate limit")) == 10.0
    assert retry_after_seconds(httpx.Response(403, text="forbidden")) is None
    reset = str(int(time.time()) + 20)
    assert (
        0
        < retry_after_seconds(httpx.Response(403, headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": reset}))
        <= 20
    )
    assert retry_after_seconds(httpx.Response(200)) is None


def test_transport_errors_are_retried_for_idempotent_methods_only() -> None:
    sleeps: list[float] = []
    with respx.mock() as router:
        get = router.get("https://x.test/a").mock(side_effect=[httpx.ConnectError("x"), httpx.Response(200)])
        post = router.post("https://x.test/a").mock(side_effect=httpx.ConnectError("x"))
        with httpx.Client() as client:
            assert (
                request_with_retries(client, "GET", "https://x.test/a", max_retries=3, sleep=sleeps.append).status_code
                == 200
            )
            with pytest.raises(httpx.ConnectError):
                request_with_retries(client, "POST", "https://x.test/a", max_retries=3, sleep=sleeps.append)
    assert get.call_count == 2 and post.call_count == 1 and len(sleeps) == 1


def test_retries_are_bounded() -> None:
    with respx.mock() as router:
        route = router.get("https://x.test/a").respond(503)
        with httpx.Client() as client:
            assert (
                request_with_retries(
                    client, "GET", "https://x.test/a", max_retries=2, sleep=lambda _s: None
                ).status_code
                == 503
            )
    assert route.call_count == 3


# ---------------------------------------------------------------------------- wiring
def test_container_overrides_and_reset(clients, github, bamboo, slack) -> None:
    assert container.github(None) is github and container.bamboo() is bamboo and container.slack() is slack
    container.reset()
    assert container.bamboo() is not bamboo
    container.reset()


def test_registered_handlers_cover_every_enqueued_job_name() -> None:
    from netdef_ci.jobs import handlers

    assert set(handlers.REGISTERED) == {
        "create_execution_by_plan",
        "create_execution_by_comment",
        "create_execution_by_command",
        "ci_job_status",
        "timeout_execution",
        "fetch_topotest_failures",
        "slack_username_to_id",
    }


def test_production_refuses_to_start_without_webhook_secret(monkeypatch, settings) -> None:
    from fastapi.testclient import TestClient

    from netdef_ci.web.app import create_app

    monkeypatch.setattr(settings, "env", "production")
    monkeypatch.setattr(settings, "webhook_secret", type(settings.webhook_secret)(""))
    with pytest.raises(RuntimeError, match="WEBHOOK_SECRET"), TestClient(create_app(init_database=False)):
        pass


# ---------------------------------------------------------------------------- worker loop & concurrency
def test_worker_loop_processes_jobs_until_stopped(session) -> None:
    seen: list[int] = []

    @job_handler("t_loop")
    def handler(n: int) -> None:
        seen.append(n)

    try:
        for i in range(3):
            queue.enqueue(session, "t_loop", [i])
        worker = queue.Worker(use_timeout=False, name="loop")
        worker.settings = worker.settings.model_copy(update={"job_sleep_delay_seconds": 0.05})
        thread = threading.Thread(target=worker.run_forever)
        thread.start()
        deadline = time.time() + 5
        while len(seen) < 3 and time.time() < deadline:
            time.sleep(0.05)
        worker.stop_event.set()
        thread.join(5)
        assert sorted(seen) == [0, 1, 2] and not thread.is_alive()
    finally:
        HANDLERS.pop("t_loop", None)
