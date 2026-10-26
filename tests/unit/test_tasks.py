#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_tasks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from netdef_ci import metrics
from netdef_ci.db import utcnow
from netdef_ci.enums import Status
from netdef_ci.models import CheckSuite, GithubUser, Job, TopotestFailure
from netdef_ci.services import tasks
from tests import factories as f


# ---------------------------------------------------------------------------- CiJobStatus
def test_ci_job_status_builds_summary_and_reconciles_when_job_finished(session, clients, bamboo, github) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.QUEUED))
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Tests", "finished": False}
    tasks.ci_job_status(session, "PROJ-PLAN-77", w.build_job.id)
    session.refresh(w.build_stage)
    assert w.build_stage.state == Status.SUCCESS


def test_ci_job_status_for_a_running_job_does_not_call_bamboo_status(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    tasks.ci_job_status(session, "PROJ-PLAN-77", w.build_job.id)  # would be 503 if Finished ran with no status


def test_ci_job_status_unknown_job_raises(session, clients) -> None:
    with pytest.raises(LookupError):
        tasks.ci_job_status(session, "X", 12345)


# ---------------------------------------------------------------------------- TimeoutExecution
def counter() -> float:
    return metrics.CI_TIMEOUTS._value.get()


def test_timeout_ignores_finished_suites(session, clients) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    assert tasks.timeout_execution(session, w.suite.id) is False
    assert session.scalars(select(Job)).all() == []


def test_timeout_reschedules_recently_updated_suites(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    assert tasks.timeout_execution(session, w.suite.id) is False
    job = session.scalars(select(Job)).one()
    assert job.handler == "timeout_execution" and job.queue == "timeout_execution" and job.args == [w.suite.id]
    assert timedelta(minutes=29) < job.run_at - utcnow() <= timedelta(minutes=30)


def test_timeout_marks_hung_suites_as_finished(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    old = utcnow() - timedelta(hours=3)
    for job in (w.build_job, w.tests_job):
        job.updated_at = old
    session.commit()
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Tests", "finished": False}
    bamboo.results["PROJ-PLAN-77"] = {}
    before = counter()
    assert tasks.timeout_execution(session, w.suite.id) is True
    assert counter() == before + 1
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SKIPPED  # hanged: leftovers are skipped


def test_timeout_for_suite_without_jobs_uses_suite_timestamps(session, clients) -> None:
    pr = f.pull_request(session)
    suite = f.check_suite(session, pr)
    f.stage(session, suite, None, status=Status.IN_PROGRESS)
    assert tasks.timeout_execution(session, suite.id) is False  # young suite: rescheduled, no crash


# ---------------------------------------------------------------------------- topotest failures
RESULT = {
    "testResults": {
        "failedTests": {
            "testResult": [
                {
                    "className": "suite.A",
                    "methodName": "test_a",
                    "durationInSeconds": 2.7,
                    "errors": {"error": [{"message": "m1"}, {"message": "m2"}]},
                },
            ]
        }
    }
}


def test_failures_are_stored_when_available(session, clients, bamboo) -> None:
    w = f.World(session)
    bamboo.job_results[w.tests_job.job_ref] = RESULT
    tasks.fetch_topotest_failures(session, w.tests_job.id, 1)
    row = session.scalars(select(TopotestFailure)).one()
    assert (row.test_suite, row.test_case, row.message, row.execution_time) == ("suite.A", "test_a", "m1\nm2", 2)


def test_missing_failures_are_retried_with_growing_delay_then_dropped(session, clients, bamboo) -> None:
    w = f.World(session)
    bamboo.job_results[w.tests_job.job_ref] = {}
    tasks.fetch_topotest_failures(session, w.tests_job.id, 1)
    job = session.scalars(select(Job)).one()
    assert job.args == [w.tests_job.id, 2] and timedelta(minutes=9) < job.run_at - utcnow() <= timedelta(minutes=10)
    tasks.fetch_topotest_failures(session, w.tests_job.id, 4)  # more than 3 attempts: give up silently
    assert len(session.scalars(select(Job)).all()) == 1
    assert session.scalars(select(TopotestFailure)).all() == []


# ---------------------------------------------------------------------------- Slack user id
def test_slack_username_resolution(session, clients, slack) -> None:
    session.add(GithubUser(github_id=1, github_login="alice"))
    session.commit()
    slack.user_ids["alice.s"] = "U777"
    assert tasks.slack_username_to_id(session, "alice", "alice.s") is True
    assert session.scalars(select(GithubUser)).one().slack_id == "U777"
    assert tasks.slack_username_to_id(session, "nobody", "x") is False


# ---------------------------------------------------------------------------- WatchDog
def test_watch_dog_reconciles_only_suites_with_running_stages(session, clients, bamboo) -> None:
    running = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    done = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    done.suite.bamboo_ci_ref = "PROJ-PLAN-DONE"
    session.commit()
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final"}
    bamboo.results["PROJ-PLAN-77"] = {
        "stages": {"stage": [{"results": {"result": [{"buildResultKey": "PROJ-PLAN-77-BLD", "state": "Successful"}]}}]}
    }
    assert tasks.watch_dog(session) == 1
    session.refresh(running.build_job)
    assert running.build_job.state == Status.SUCCESS


def test_watch_dog_survives_a_broken_suite(session, clients, bamboo) -> None:
    f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED)).suite.bamboo_ci_ref = "PROJ-PLAN-2"
    session.commit()

    def explode(ref):
        if ref == "PROJ-PLAN-77":
            raise RuntimeError("boom")
        return {"currentStage": "Tests", "finished": False}

    bamboo.build_status = explode
    assert tasks.watch_dog(session) == 2  # the first failure does not stop the second suite


# ---------------------------------------------------------------------------- PrBambooSync
@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (None, "unreachable"),
        ({}, "unreachable"),
        ({"currentStage": "Final"}, "stale"),
        ({"message": "stopped"}, "stale"),
        ({"currentStage": "Tests", "progress": {"percentageCompleted": 2.5}}, "stale"),
        ({"currentStage": "Tests", "finished": False, "progress": {"percentageCompleted": 0.3}}, "ok_running"),
    ],
)
def test_classification(status, expected) -> None:
    assert tasks.classify(status) == expected


def test_pr_bamboo_sync_fixes_stale_suites(session, clients, bamboo, github) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    w.suite.commit_sha_ref = "a" * 40
    session.commit()
    stamp = (utcnow() - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    github.pulls = [
        {"number": w.pr.github_pr_id, "updated_at": stamp, "head": {"sha": "a" * 40}},
        {
            "number": 999,
            "updated_at": (utcnow() - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "head": {"sha": "z" * 40},
        },
    ]
    github.listed_check_runs["in_progress"] = [{"id": 1}]
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final"}
    bamboo.results["PROJ-PLAN-77"] = {}
    lines: list[str] = []
    grouped = tasks.pr_bamboo_sync(session, out=lines.append)
    assert [r["bamboo_ref"] for r in grouped["stale"]] == ["PROJ-PLAN-77"]
    assert any("Stale (syncing): 1" in line for line in lines)
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SKIPPED  # reconciled through Finished


# ---------------------------------------------------------------------------- SingleSync
def test_single_sync(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.results["PROJ-PLAN-77"] = {
        "stages": {
            "stage": [
                {
                    "results": {
                        "result": [
                            {
                                "buildResultKey": "PROJ-PLAN-77-BLD",
                                "state": "Failed",
                                "plan": {"shortName": "Build job"},
                            },
                            {
                                "buildResultKey": "PROJ-PLAN-77-NEW",
                                "state": "Successful",
                                "plan": {"shortName": "New job"},
                            },
                            {
                                "buildResultKey": "PROJ-PLAN-77-TST",
                                "state": "Running",
                                "plan": {"shortName": "Tests job"},
                            },
                        ]
                    }
                }
            ]
        }
    }
    out: list[str] = []
    assert tasks.single_sync(session, "PROJ-PLAN-77", out.append) is True
    session.refresh(w.build_job)
    assert w.build_job.state == Status.FAILURE
    assert session.scalars(select(CheckSuite)).one().ci_jobs[-1].state == Status.SUCCESS
    assert "Ignored" in out
    assert tasks.single_sync(session, "NOPE-1", out.append) is False
