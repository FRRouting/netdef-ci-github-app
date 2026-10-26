#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_models.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select

from netdef_ci.db import utcnow
from netdef_ci.enums import Status
from netdef_ci.models import AuditStatus, CheckSuite
from tests import factories as f


def test_job_transitions_write_audit_and_skip_github_without_check_ref(session, clients, github) -> None:
    w = f.World(session)
    w.build_job.in_progress(github)
    w.build_job.success(github)
    assert w.build_job.state == Status.SUCCESS
    audits = list(
        session.scalars(
            select(AuditStatus).where(AuditStatus.auditable_type == "CiJob", AuditStatus.auditable_id == w.build_job.id)
        )
    )
    assert [Status(a.status) for a in audits] == [Status.IN_PROGRESS, Status.SUCCESS]
    assert github.calls == []  # jobs never own a GitHub check run in the Ruby app


def test_job_with_check_ref_updates_github(session, clients, github) -> None:
    w = f.World(session)
    w.build_job.check_ref = "900"
    w.build_job.failure(github, {"title": "t", "summary": "s"})
    assert github.calls_named("failure") == [("900", {"title": "t", "summary": "s"})]


def test_job_execution_time_uses_first_in_progress_and_success_or_failure(session, clients, github) -> None:
    w = f.World(session)
    w.build_job.in_progress(github)
    w.build_job.success(github)
    started, finished = session.scalars(select(AuditStatus).order_by(AuditStatus.id)).all()
    started.created_at = utcnow() - timedelta(seconds=90)
    finished.created_at = started.created_at + timedelta(seconds=75, milliseconds=900)
    session.commit()
    w.build_job.update_execution_time()
    assert w.build_job.execution_time == 75  # truncated like Rails' integer cast


def test_stage_enqueue_creates_check_run_and_stores_reference(session, clients, github) -> None:
    w = f.World(session)
    w.build_stage.enqueue(github, output={"title": "x", "summary": "y"})
    run = github.by_name("[CI] Build")[0]
    assert w.build_stage.check_ref == str(run["id"])
    assert run["status"] == "queued" and run["output"] == {"title": "x", "summary": "y"}


def test_stage_in_progress_is_idempotent_and_notifies(session, clients, github, slack) -> None:
    w = f.World(session)
    w.build_stage.check_ref = None
    session.commit()
    w.build_stage.in_progress(github, output={"title": "a", "summary": "b"})
    w.build_stage.in_progress(github)
    assert len(github.calls_named("create")) == 1
    assert slack.names() == ["stage_in_progress"]


def test_stage_finish_creates_a_fresh_check_run_like_ruby(session, clients, github, slack) -> None:
    w = f.World(session)
    old_ref = w.build_stage.check_ref
    w.build_stage.success(github, output={"title": "t", "summary": "s"})
    assert w.build_stage.state == Status.SUCCESS
    assert w.build_stage.check_ref != old_ref
    assert github.check_runs[int(w.build_stage.check_ref)]["conclusion"] == "success"
    assert slack.names() == ["stage_finished"]


def test_check_suite_running_and_finished(session) -> None:
    w = f.World(session)
    assert w.suite.is_running() and w.suite.is_in_progress() and not w.suite.is_finished()
    w.build_stage.status = Status.SUCCESS
    w.tests_stage.status = Status.FAILURE
    session.commit()
    assert w.suite.is_finished()


def test_stages_failure_returns_distinct_stages_with_failed_jobs(session) -> None:
    w = f.World(session)
    w.tests_job.status = Status.FAILURE
    f.job(session, w.suite, w.tests_stage, status=Status.CANCELLED)
    session.commit()
    assert [s.id for s in w.suite.stages_failure()] == [w.tests_stage.id]


def test_current_execution_is_per_plan_and_latest(session) -> None:
    w = f.World(session)
    newer = f.check_suite(session, w.pr, w.plan)
    other_plan = f.plan(session, name="other", bamboo="X-Y")
    unplanned = f.check_suite(session, w.pr, None)
    assert w.pr.current_execution(newer)
    assert not w.pr.current_execution(w.suite)
    assert w.pr.current_execution(unplanned)  # plan NULL group is independent
    assert w.pr.current_execution_by_plan(other_plan) is None


def test_stage_output_in_progress_lists_running_jobs(session, settings) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    out = w.build_stage.output_in_progress()
    assert out["title"] == "Build summary"
    assert "Jobs in progress: 1/1" in out["summary"]
    assert f"https://ci.example.test/browse/{w.build_job.job_ref}" in out["summary"]
    assert "PROJ-PLAN-77" in out["summary"]


def test_pull_request_finished(session) -> None:
    pr = f.pull_request(session)
    assert pr.is_finished()
    w = f.World(session)
    assert not w.pr.is_finished()
    assert isinstance(session.get(CheckSuite, w.suite.id), CheckSuite)
