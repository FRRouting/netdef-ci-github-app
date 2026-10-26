#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_summary.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest

from netdef_ci.enums import Status
from netdef_ci.services.summary import Summary
from tests import factories as f


def build(session, job, **kw):
    session.refresh(job)
    Summary(job, **kw).build_summary()
    for obj in session.identity_map.values():
        session.refresh(obj)


def test_running_job_keeps_stage_in_progress_with_summary(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    build(session, w.build_job)
    assert w.build_stage.state == Status.IN_PROGRESS
    output = github.calls_named("in_progress")[-1][1]
    assert output["title"] == "Build summary"
    assert "Jobs in progress: 1/1" in output["summary"] and "Last updated:" in output["summary"]
    assert github.calls_named("success") == [] and github.calls_named("failure") == []


def test_finished_stage_succeeds_and_next_stage_starts(session, clients, github, slack) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.QUEUED))
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    build(session, w.build_job)
    assert w.build_stage.state == Status.SUCCESS
    assert github.check_runs[int(w.build_stage.check_ref)]["conclusion"] == "success"
    assert w.build_stage.execution_time is None  # no audit trail in this synthetic setup
    assert w.tests_stage.state == Status.IN_PROGRESS  # next stage announced as running
    assert "stage_finished" in slack.names()


def test_failed_mandatory_stage_cancels_following_stages_and_jobs(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.FAILURE, Status.QUEUED))
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    build(session, w.build_job)
    assert w.build_stage.state == Status.FAILURE
    assert w.tests_stage.state == Status.CANCELLED and w.tests_job.state == Status.CANCELLED
    cancelled = github.check_runs[int(w.tests_stage.check_ref)]
    assert cancelled["conclusion"] == "cancelled"
    assert "The previous stage failed and the remaining tests will be canceled." in cancelled["output"]["summary"]
    assert (
        "Details at [https://ci.example.test/browse/PROJ-PLAN-77](https://ci.example.test/browse/PROJ-PLAN-77)."
        in cancelled["output"]["summary"]
    )


def test_failed_optional_stage_does_not_cancel_next(session, clients) -> None:
    w = f.World(session, statuses=(Status.FAILURE, Status.QUEUED))
    w.configs[0].mandatory = False
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    build(session, w.build_job)
    assert w.build_stage.state == Status.FAILURE
    assert w.tests_stage.state != Status.CANCELLED


def test_cancelled_stage_is_left_alone(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.CANCELLED, Status.CANCELLED))
    build(session, w.build_job)
    assert github.calls == []


def test_earlier_stuck_stage_is_finalized_when_a_later_stage_reports(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.IN_PROGRESS))
    w.build_stage.status = Status.IN_PROGRESS  # stuck: its only job already succeeded
    session.commit()
    build(session, w.tests_job)
    assert w.build_stage.state == Status.SUCCESS


def test_stage_with_failed_job_ends_in_failure(session, clients) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.IN_PROGRESS))
    f.job(session, w.suite, w.tests_stage, "other", Status.CANCELLED)
    w.tests_job.status = Status.SUCCESS
    session.commit()
    build(session, w.tests_job)
    assert w.tests_stage.state == Status.FAILURE


def test_agent_is_recorded_for_watchdog_runs(session, clients) -> None:
    from sqlalchemy import select

    from netdef_ci.models import AuditStatus

    w = f.World(session, statuses=(Status.SUCCESS, Status.QUEUED))
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    build(session, w.build_job, agent="WatchDog")
    agents = {a.agent for a in session.scalars(select(AuditStatus).where(AuditStatus.auditable_type == "Stage"))}
    assert "WatchDog" in agents


def test_job_without_stage_gets_it_from_the_running_plan(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    orphan = f.job(session, w.suite, None, "Build job", Status.IN_PROGRESS, "PROJ-PLAN-77-ORPHAN")
    bamboo.jobs["PROJ-PLAN-77"] = [{"name": "Build job", "job_ref": "PROJ-PLAN-77-ORPHAN", "stage": "Build"}]
    build(session, orphan)
    assert orphan.stage_id == w.build_stage.id


def test_job_missing_from_running_plan_raises(session, clients, bamboo) -> None:
    w = f.World(session)
    orphan = f.job(session, w.suite, None, "ghost", Status.IN_PROGRESS)
    bamboo.jobs["PROJ-PLAN-77"] = []
    session.refresh(orphan)
    with pytest.raises(LookupError):
        Summary(orphan).build_summary()
