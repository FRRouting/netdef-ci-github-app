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

import pytest
from sqlalchemy import select

from netdef_ci.cli.main import main
from netdef_ci.enums import Status
from netdef_ci.models import Job
from tests import factories as f
from tests.conftest import IS_PG


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


@pytest.mark.skipif(not IS_PG, reason="alembic commands run against PostgreSQL")
def test_migrate_and_stamp_commands(engine, capsys) -> None:
    assert main(["migrate"]) == 0
    assert "already at revision 0002_python_tables" in capsys.readouterr().out
    assert main(["stamp-ruby-schema", "--revision", "0002_python_tables"]) == 0


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
