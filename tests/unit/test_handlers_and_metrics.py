#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_handlers_and_metrics.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""Registered job handlers executed through the queue, and the Prometheus collectors."""

from __future__ import annotations

import os
from datetime import timedelta
from pathlib import Path

from sqlalchemy import select

from netdef_ci import db, metrics
from netdef_ci.db import utcnow
from netdef_ci.enums import Status
from netdef_ci.jobs import (
    handlers,  # noqa: F401
    queue,
)
from netdef_ci.models import CheckSuite, GithubUser, Job, TopotestFailure
from tests import factories as f
from tests import payloads


def drain() -> int:
    worker = queue.Worker(use_timeout=False, name="t")
    done = 0
    while worker.run_once():
        done += 1
    return done


def test_every_handler_runs_through_the_queue(session, clients, bamboo, github, slack) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.default_jobs = [{"name": "Build job", "job_ref": "PROJ-PLAN-1-BLD", "stage": "Build"}]
    github.commits = [[{"sha": "c" * 40}]]
    bamboo.job_results[w.tests_job.job_ref] = {
        "testResults": {
            "failedTests": {
                "testResult": [
                    {
                        "className": "s",
                        "methodName": "m",
                        "durationInSeconds": 1,
                        "errors": {"error": [{"message": "x"}]},
                    }
                ]
            }
        }
    }
    session.add(GithubUser(github_id=9, github_login="zoe"))
    slack.user_ids["zoe.s"] = "U55"
    session.commit()
    queue.enqueue(
        session,
        "create_execution_by_plan",
        [w.pr.id, payloads.pull_request(number=w.pr.github_pr_id), w.plan.id],
        max_attempts=1,
    )
    queue.enqueue(
        session,
        "create_execution_by_comment",
        [w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id],
        max_attempts=1,
    )
    queue.enqueue(
        session,
        "create_execution_by_command",
        [w.plan.id, w.suite.id, payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)],
        max_attempts=1,
    )
    queue.enqueue(session, "ci_job_status", ["PROJ-PLAN-77", w.build_job.id])
    queue.enqueue(session, "timeout_execution", [w.suite.id])
    queue.enqueue(session, "fetch_topotest_failures", [w.tests_job.id, 1])
    queue.enqueue(session, "slack_username_to_id", ["zoe", "zoe.s"])
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Tests", "finished": False}
    assert drain() >= 7
    session.expire_all()
    leftover = [(j.handler, j.last_error) for j in session.scalars(select(Job)) if j.last_error]
    assert leftover == []  # no handler failed
    assert len(session.scalars(select(CheckSuite)).all()) >= 4
    assert session.scalars(select(TopotestFailure)).one().test_case == "m"
    assert session.scalars(select(GithubUser).where(GithubUser.github_login == "zoe")).one().slack_id == "U55"


def test_stale_metric_files_of_dead_processes_are_removed() -> None:
    directory = Path(os.environ["PROMETHEUS_MULTIPROC_DIR"])
    dead, alive = directory / "counter_999999.db", directory / f"counter_{os.getppid()}.db"
    dead.write_bytes(b"x")
    alive.write_bytes(b"x")  # a process that is still running keeps its file (never touch this process' own files)
    try:
        metrics.cleanup_stale_metric_files()
        assert not dead.exists() and alive.exists()
    finally:
        alive.unlink(missing_ok=True)


def test_database_gauges_reflect_queue_and_ci_state(session, clients) -> None:
    now = utcnow()
    queue.enqueue(session, "x", ["a"], queue="1")  # pending
    queue.enqueue(session, "x", ["b"], queue="1", delay_seconds=3600)  # scheduled
    stuck = queue.enqueue(session, "x", ["c"], queue="2")
    stuck.locked_at = now - timedelta(hours=1)
    running = queue.enqueue(session, "x", ["d"], queue="2")
    running.locked_at = now
    maxed = queue.enqueue(session, "x", ["e"], queue="3", max_attempts=2)
    maxed.attempts = 2
    session.commit()
    f.World(session, statuses=(Status.SUCCESS, Status.IN_PROGRESS))
    text = metrics.render(db.session_factory(), db.get_engine()).decode()

    def value(line: str) -> float:
        return float(next(x for x in text.splitlines() if x.startswith(line)).split()[-1])

    assert value('delayed_jobs_pending{queue="1"}') == 1
    assert value('delayed_jobs_scheduled{queue="1"}') == 1
    assert value('delayed_jobs_locked_too_long{queue="2"}') == 1
    assert value('delayed_jobs_running{queue="2"}') == 2
    assert value('delayed_jobs_max_attempts_reached{queue="3"}') == 1
    assert value('ci_jobs_total{status="success"}') == 1 and value('ci_jobs_total{status="in_progress"}') == 1
    assert value('ci_stages_total{status="success"}') == 1
    assert "delayed_jobs_table{" in text and 'job_class="x"' in text


def test_bamboo_and_slack_trackers_count_outcomes() -> None:
    class Resp:
        status_code = 500

    assert metrics.track_bamboo("probe_err", lambda: Resp()).status_code == 500  # type: ignore[union-attr]
    assert metrics.track_bamboo("probe_none", lambda: None) is None

    def boom() -> None:
        raise RuntimeError

    assert metrics.track_bamboo("probe_raise", boom) is None
    assert metrics.track_slack("probe", boom) is None
    assert metrics.track_slack("probe_ok", lambda: object()) is not None
    text = metrics.render().decode()
    assert 'bamboo_api_requests_total{operation="probe_err",status="error"}' in text
    assert 'bamboo_api_requests_total{operation="probe_raise",status="error"}' in text
    assert 'slack_notifications_total{status="sent",type="probe_ok"}' in text
