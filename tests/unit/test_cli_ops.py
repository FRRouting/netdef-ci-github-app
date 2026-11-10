#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_cli_ops.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""Operational CLI commands (worker, cron tasks, migrations, configuration check)."""

from __future__ import annotations

import os
import signal
import threading

from sqlalchemy import select

from netdef_ci.cli.main import main
from netdef_ci.enums import Status
from netdef_ci.models import Job
from tests import factories as f


def test_watch_dog_and_single_sync_commands(session, clients, bamboo, capsys) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final"}
    bamboo.results["PROJ-PLAN-77"] = {
        "stages": {
            "stage": [
                {
                    "results": {
                        "result": [
                            {
                                "buildResultKey": "PROJ-PLAN-77-BLD",
                                "state": "Successful",
                                "plan": {"shortName": "Build job"},
                            }
                        ]
                    }
                }
            ]
        }
    }
    assert main(["watch-dog"]) == 0
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SUCCESS
    assert main(["single-sync", "NOPE-1"]) == 1
    assert "Please inform the CI" in capsys.readouterr().out
    assert main(["single-sync", "PROJ-PLAN-77"]) == 0


def test_pr_bamboo_sync_command(session, clients, github, capsys) -> None:
    f.World(session)
    github.pulls = []
    assert main(["pr-bamboo-sync"]) == 0
    out = capsys.readouterr().out
    assert "Time window:" in out and "Total checked  : 0" in out


def test_worker_command_runs_jobs_and_stops_on_sigterm(session, clients) -> None:
    from netdef_ci.jobs import queue
    from netdef_ci.jobs.registry import HANDLERS, job_handler

    seen: list[int] = []

    @job_handler("t_cli")
    def handler(n: int) -> None:
        seen.append(n)

    try:
        queue.enqueue(session, "t_cli", [1], queue="cli-queue")
        queue.enqueue(session, "t_cli", [2], queue="other-queue")
        threading.Timer(1.5, lambda: os.kill(os.getpid(), signal.SIGTERM)).start()
        old = signal.getsignal(signal.SIGTERM)
        try:
            assert main(["worker", "--queues", "cli-queue"]) == 0
        finally:
            signal.signal(signal.SIGTERM, old)
        assert seen == [1]  # the other queue is not consumed by this worker
        session.expire_all()
        assert [j.args for j in session.scalars(select(Job))] == [[2]]
    finally:
        HANDLERS.pop("t_cli", None)


def test_check_config_reports_problems(session, monkeypatch, settings, capsys, tmp_path) -> None:
    from pydantic import SecretStr

    monkeypatch.setattr(settings, "webhook_secret", SecretStr(""))
    monkeypatch.setattr(settings, "github_apps_file", str(tmp_path / "missing.toml"))
    monkeypatch.setattr(settings, "bamboo_username", None)
    monkeypatch.setattr(settings, "bamboo_password", None)
    monkeypatch.setattr(settings, "slack_bot_url", None)
    code = main(["check-config"])
    captured = capsys.readouterr()
    assert code == 1
    assert "WEBHOOK_SECRET is empty" in captured.err and "GITHUB_APPS_FILE unreadable" in captured.err
    assert "Bamboo credentials not found" in captured.err and "SLACK_BOT_URL not set" in captured.out


def test_check_bamboo_reports_each_probe(clients, capsys) -> None:
    import httpx

    from netdef_ci import container
    from netdef_ci.clients.bamboo import BambooClient
    from netdef_ci.helpers.config import get_settings

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("/info"):
            return httpx.Response(200, json={"version": "10"})
        if path.endswith("/plan/NOPE"):
            return httpx.Response(404)
        return httpx.Response(200, json={"stages": {"stage": []}})

    container.override(bamboo=BambooClient(get_settings(), transport=httpx.MockTransport(handler)))
    assert main(["check-bamboo"]) == 0
    assert "ok   server info: 200" in capsys.readouterr().out
    assert main(["check-bamboo", "--plan", "NOPE", "--result", "PROJ-PLAN-1"]) == 1
    out = capsys.readouterr().out
    assert "FAIL plan NOPE: 404 (not found)" in out and "ok   execution PROJ-PLAN-1: 200" in out
    assert "jobs found in PROJ-PLAN-1: 0" in out


def test_check_bamboo_explains_disabled_basic_auth(clients, capsys) -> None:
    import httpx

    from netdef_ci import container
    from netdef_ci.clients.bamboo import BambooClient
    from netdef_ci.helpers.config import get_settings

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, json={"message": "Basic Authentication has been disabled on this instance."})

    container.override(bamboo=BambooClient(get_settings(), transport=httpx.MockTransport(handler)))
    assert main(["check-bamboo"]) == 1
    out = capsys.readouterr().out
    assert "Authentication: Basic" in out
    assert (
        "FAIL server info: 403 (Basic Authentication is disabled on Bamboo: use a service account or BAMBOO_TOKEN)"
        in out
    )


def test_check_bamboo_reports_the_service_account_token(clients, capsys, settings, monkeypatch) -> None:
    import httpx
    from pydantic import SecretStr

    from netdef_ci import container
    from netdef_ci.clients.bamboo import BambooClient

    monkeypatch.setattr(settings, "bamboo_client_id", "cid")
    monkeypatch.setattr(settings, "bamboo_client_secret", SecretStr("csecret"))
    token_status = {"code": 200}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/oauth2/latest/token"):
            if token_status["code"] != 200:
                return httpx.Response(
                    token_status["code"], json={"errors": ["Please ensure that your server is using HTTPS"]}
                )
            return httpx.Response(200, json={"access_token": "t", "expires_in": 3600, "scope": "WRITE"})
        return httpx.Response(200 if request.headers.get("authorization") == "Bearer t" else 401, json={})

    container.override(bamboo=BambooClient(settings, transport=httpx.MockTransport(handler)))
    assert main(["check-bamboo"]) == 0
    out = capsys.readouterr().out
    assert "Authentication: service account" in out and "ok   service account token (scope: WRITE)" in out
    token_status["code"] = 400
    container.override(bamboo=BambooClient(settings, transport=httpx.MockTransport(handler)))
    assert main(["check-bamboo"]) == 1
    assert "FAIL service account token: HTTP 400" in capsys.readouterr().out


def test_check_config_rejects_half_a_service_account(session, monkeypatch, settings, capsys) -> None:
    monkeypatch.setattr(settings, "bamboo_client_id", "cid")
    monkeypatch.setattr(settings, "bamboo_client_secret", None)
    assert main(["check-config"]) == 1
    assert "BAMBOO_CLIENT_ID and BAMBOO_CLIENT_SECRET must be set together" in capsys.readouterr().err


def test_check_bamboo_reports_connection_errors(clients, capsys) -> None:
    import httpx

    from netdef_ci import container
    from netdef_ci.clients.bamboo import BambooClient
    from netdef_ci.helpers.config import get_settings

    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    container.override(bamboo=BambooClient(get_settings(), transport=httpx.MockTransport(down)))
    assert main(["check-bamboo"]) == 1
    assert "FAIL server info: ConnectError: refused" in capsys.readouterr().out
