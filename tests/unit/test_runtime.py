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

from netdef_ci import container
from netdef_ci.clients.http import MAX_RETRY_AFTER_SECONDS, request_with_retries, retry_after_seconds
from netdef_ci.jobs import queue
from netdef_ci.jobs.registry import HANDLERS, job_handler
from netdef_ci.logs import Log, SizeRotatingFileHandler, redact


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


def _write(handler: logging.Handler, message: str) -> None:
    handler.emit(logging.LogRecord("t", logging.INFO, __file__, 1, message, None, None))


def test_size_rotation_keeps_the_configured_number_of_files(tmp_path) -> None:
    handler = SizeRotatingFileHandler(tmp_path / "github_http.log", max_bytes=10, files=3)
    for index in range(5):
        _write(handler, f"line-{index}-0123456789")
    handler.close()
    assert sorted(p.name for p in tmp_path.glob("github_http.log*")) == [
        "github_http.log",
        "github_http.log.1",
        "github_http.log.2",
        "github_http.log.lock",
    ]
    assert (tmp_path / "github_http.log").read_text().startswith("line-4")
    assert (tmp_path / "github_http.log.2").read_text().startswith("line-2")


def test_size_rotation_with_a_single_file_restarts_it(tmp_path) -> None:
    handler = SizeRotatingFileHandler(tmp_path / "github_http.log", max_bytes=10, files=1)
    _write(handler, "first-0123456789")
    _write(handler, "second")
    handler.close()
    assert sorted(p.name for p in tmp_path.glob("github_http.log*")) == ["github_http.log", "github_http.log.lock"]
    assert (tmp_path / "github_http.log").read_text().strip() == "second"


def test_size_rotation_by_another_process_is_followed(tmp_path) -> None:
    first = SizeRotatingFileHandler(tmp_path / "github_http.log", max_bytes=10, files=2)
    second = SizeRotatingFileHandler(tmp_path / "github_http.log", max_bytes=10, files=2)
    _write(first, "a-0123456789")
    _write(second, "b")  # rotates; `first` still holds the old (renamed) file open
    _write(first, "c")
    first.close()
    second.close()
    assert (tmp_path / "github_http.log").read_text().split() == ["b", "c"]
    assert (tmp_path / "github_http.log.1").read_text().split() == ["a-0123456789"]


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


def test_every_attempt_is_logged_with_method_url_and_status(caplog) -> None:
    logger = logging.getLogger("test_http_attempts")
    with respx.mock() as router:
        router.get("https://x.test/a").mock(side_effect=[httpx.ConnectError("refused"), httpx.Response(200)])
        router.post("https://x.test/b").respond(422)
        with httpx.Client() as client, caplog.at_level(logging.INFO, logger="test_http_attempts"):
            request_with_retries(client, "GET", "https://x.test/a", max_retries=1, sleep=lambda _s: None, logger=logger)
            request_with_retries(
                client, "POST", "https://x.test/b", max_retries=1, sleep=lambda _s: None, params={"x": 1}, logger=logger
            )
    assert [(r.levelname, r.getMessage()) for r in caplog.records] == [
        ("WARNING", "GET https://x.test/a -> ConnectError: refused"),
        ("INFO", "GET https://x.test/a -> 200"),
        ("WARNING", "POST https://x.test/b?x=1 -> 422"),
    ]


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
