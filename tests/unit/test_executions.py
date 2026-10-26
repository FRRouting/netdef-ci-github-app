#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_executions.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from netdef_ci.db import utcnow
from netdef_ci.enums import Status
from netdef_ci.models import AuditRetry, CheckSuite, CiJob, GithubUser, Job, Stage
from netdef_ci.services.executions import CreateExecutionByCommand, CreateExecutionByComment, CreateExecutionByPlan
from tests import factories as f
from tests import payloads

JOBS = [
    {"name": "Build job", "job_ref": "PROJ-PLAN-1-BLD", "stage": "Build"},
    {"name": "Tests job", "job_ref": "PROJ-PLAN-1-TST", "stage": "Tests"},
    {"name": "Unmapped", "job_ref": "PROJ-PLAN-1-X", "stage": "Unknown stage"},
]


@pytest.fixture
def ready(session, clients, bamboo):
    """Repository with one plan, two configured stages and a PR without executions yet."""
    f.default_stage_configs(session)
    pr = f.pull_request(session, number=7)
    plan = f.plan(session, pull_request=pr)
    bamboo.default_jobs = JOBS
    return pr, plan


def test_new_execution_starts_plan_and_creates_stages_and_jobs(session, ready, bamboo, github, slack) -> None:
    pr, plan = ready
    status = CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id)
    assert status == (200, "Pull Request created")
    suite = session.scalars(select(CheckSuite)).one()
    assert (suite.author, suite.commit_sha_ref, suite.base_sha_ref, suite.merge_branch, suite.work_branch) == (
        "alice",
        payloads.SHA,
        payloads.BASE_SHA,
        "main",
        "feature",
    )
    assert suite.plan_id == plan.id and suite.bamboo_ci_ref == "PROJ-PLAN-1"
    assert bamboo.submissions[0]["variables"] == [{"name": "signature_secret", "value": "test-secret"}]
    assert bamboo.comments and bamboo.comments[0][0] == "PROJ-PLAN-1"
    stages = session.scalars(select(Stage).order_by(Stage.id)).all()
    assert [(s.name, s.state) for s in stages] == [("Build", Status.QUEUED), ("Tests", Status.QUEUED)]
    assert [r["name"] for r in github.check_runs.values()] == ["[CI] Build", "[CI] Tests"]
    jobs = session.scalars(select(CiJob).order_by(CiJob.id)).all()
    assert [(j.name, j.stage.name, j.state) for j in jobs] == [
        ("Build job", "Build", Status.QUEUED),
        ("Tests job", "Tests", Status.QUEUED),
    ]
    timeout = session.scalars(select(Job).where(Job.handler == "timeout_execution")).one()
    assert timeout.args == [suite.id] and timedelta(minutes=29) < timeout.run_at - utcnow() <= timedelta(minutes=30)
    assert slack.names() == ["started"]
    assert session.scalars(select(GithubUser)).one().github_id == 4242


def test_previous_running_execution_is_cancelled_and_linked(session, ready, bamboo, github) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    old = w.suite
    code = CreateExecutionByPlan.run(
        session, w.pr.id, payloads.pull_request(sha="9" * 40, number=w.pr.github_pr_id), w.plan.id
    )
    assert code == (200, "Pull Request created")
    for obj in (old, w.build_job, w.tests_job, w.build_stage, w.tests_stage):
        session.refresh(obj)
    assert (w.build_job.state, w.tests_job.state) == (Status.CANCELLED, Status.CANCELLED)
    assert (w.build_stage.state, w.tests_stage.state) == (Status.CANCELLED, Status.CANCELLED)
    assert old.stopped_in_stage_id == w.build_stage.id
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert new.id != old.id and new.cancelled_previous_check_suite_id == old.id
    assert bamboo.stopped == ["PROJ-PLAN-77"]
    assert bamboo.cancel_comments == [("PROJ-PLAN-77", "PROJ-PLAN-1")]
    assert len(github.calls_named("cancelled")) == 2  # one check run per stage; jobs own no GitHub check run


def test_finished_previous_execution_is_not_stopped(session, ready, bamboo) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    CreateExecutionByPlan.run(session, w.pr.id, payloads.pull_request(number=w.pr.github_pr_id), w.plan.id)
    assert bamboo.stopped == [] and bamboo.cancel_comments == []


@pytest.mark.parametrize(
    ("status", "text", "expected"), [(429, "reached the maximum number of concurrent builds", 429), (500, "boom", 500)]
)
def test_bamboo_rejection_creates_no_stages(session, ready, bamboo, status, text, expected) -> None:
    pr, plan = ready
    bamboo.submit_status, bamboo.submit_text = status, text
    assert CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id) == (
        expected,
        "Failed to create CI Plan",
    )
    assert session.scalars(select(Stage)).all() == [] and session.scalars(select(Job)).all() == []


def test_unreachable_bamboo_is_418(session, ready, bamboo) -> None:
    pr, plan = ready
    bamboo.unreachable = True
    assert CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id)[0] == 418


def test_empty_running_plan_is_422(session, ready, bamboo) -> None:
    pr, plan = ready
    bamboo.default_jobs = []
    assert CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id) == (
        422,
        "Failed to fetch RunningPlan",
    )


def test_missing_plan_and_invalid_payload(session, ready) -> None:
    pr, plan = ready
    assert CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), 9999) == (422, "Plan not found")
    bad = payloads.pull_request()
    del bad["pull_request"]["head"]["sha"]
    assert CreateExecutionByPlan.run(session, pr.id, bad, plan.id) == (422, "Failed to save Check Suite")


def test_multi_plan_names_stages_per_plan(session, ready, monkeypatch, settings) -> None:
    pr, plan = ready
    other = f.plan(session, name="plan-b", bamboo="PROJ-B", pull_request=pr)
    monkeypatch.setattr(settings, "multi_plan", True)
    CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id)
    names = [s.name for s in session.scalars(select(Stage).order_by(Stage.id))]
    assert names == ["Build - plan-a", "Tests - plan-a"]
    assert other


def test_start_in_progress_stage_is_announced_immediately(session, clients, bamboo, github) -> None:
    configs = f.default_stage_configs(session)
    configs[0].start_in_progress = True
    session.commit()
    pr = f.pull_request(session, number=7)
    plan = f.plan(session, pull_request=pr)
    bamboo.default_jobs = JOBS
    CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id)
    build_stage = session.scalars(select(Stage).where(Stage.name == "Build")).one()
    job = session.scalars(select(CiJob).where(CiJob.name == "Build job")).one()
    assert build_stage.state == Status.IN_PROGRESS and job.state == Status.IN_PROGRESS


def test_old_checks_of_this_app_are_skipped_but_foreign_ones_are_not(session, ready, github) -> None:
    pr, plan = ready
    github.listed_check_runs["queued"] = [
        {"id": 1, "name": "[CI] Removed stage", "app": {"name": "NetDEF CI Hook"}},
        {"id": 2, "name": "[CI] Build", "app": {"name": "NetDEF CI Hook"}},
        {"id": 3, "name": "lint", "app": {"name": "Other App"}},
    ]
    CreateExecutionByPlan.run(session, pr.id, payloads.pull_request(), plan.id)
    skipped = github.calls_named("skipped")
    assert [c[0] for c in skipped] == [1]
    assert skipped[0][1] == {"title": "[CI] Removed stage summary", "summary": "Old test suite, skipping..."}


# ---------------------------------------------------------------------------- ci:rerun comment
def test_rerun_comment_uses_last_commit_of_the_pr(session, ready, bamboo, github, slack) -> None:
    w = f.World(session)
    github.commits = [[{"sha": "a" * 40}, {"sha": "c" * 40}]]
    status = CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    assert status == (201, "Starting re-run (comment)")
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert new.id != w.suite.id
    assert (new.commit_sha_ref, new.author, new.re_run, new.plan_id, new.work_branch, new.merge_branch) == (
        "c" * 40,
        "bob",
        True,
        w.plan.id,
        "feature",
        "main",
    )
    assert new.bamboo_ci_ref == "PROJ-PLAN-1"
    audit = session.scalars(select(AuditRetry)).one()
    assert (audit.retry_type, audit.github_username, audit.github_id, audit.check_suite_id) == (
        "full",
        "bob",
        "777",
        new.id,
    )
    assert slack.names()[0] == "started"
    queued = session.scalars(select(CiJob).where(CiJob.check_suite_id == new.id)).all()
    assert {j.name: j.state for j in queued} == {"Build job": Status.QUEUED, "Tests job": Status.QUEUED}


def test_rerun_comment_with_sha_reuses_the_old_suite_data(session, ready, bamboo, github) -> None:
    w = f.World(session)
    old = f.check_suite(session, w.pr, w.plan, sha="abcdef1234" + "0" * 30)
    status = CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun #ABCDEF1\n", number=w.pr.github_pr_id), w.plan.id
    )
    assert status[0] == 201
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert new.commit_sha_ref == old.commit_sha_ref and new.re_run and new.author == old.author
    assert github.calls_named("create")  # check runs for the new execution


def test_rerun_comment_with_short_sha_found_in_pr_commits(session, ready, github) -> None:
    w = f.World(session)
    github.commits = [[{"sha": "1234567" + "0" * 33}, {"sha": "e" * 40}]]
    CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun #1234567", number=w.pr.github_pr_id), w.plan.id
    )
    assert (
        session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first().commit_sha_ref
        == "1234567" + "0" * 33
    )


def test_rerun_comment_stops_running_execution_of_the_plan(session, ready, bamboo, github) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    github.commits = [[{"sha": "c" * 40}]]
    CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    session.refresh(w.build_job)
    assert w.build_job.state == Status.CANCELLED and "PROJ-PLAN-77" in bamboo.stopped
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert new.cancelled_previous_check_suite_id == w.suite.id


def test_rerun_comment_without_commits_creates_nothing(session, ready, github) -> None:
    w = f.World(session)
    github.commits = []
    status = CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    assert status == (404, "Failed to create a check suite")
    assert session.scalars(select(CheckSuite)).all() == [w.suite]


def test_rerun_marks_jobs_removed_from_the_plan_as_skipped_in_old_suites(session, ready, bamboo, github) -> None:
    w = f.World(session)
    github.commits = [[{"sha": w.suite.commit_sha_ref}]]
    removed = f.job(session, w.suite, w.build_stage, "Removed job", Status.FAILURE, "PROJ-PLAN-77-OLD")
    bamboo.jobs["PROJ-PLAN-77"] = [{"name": "Build job", "job_ref": "PROJ-PLAN-77-BLD", "stage": "Build"}]
    CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    session.refresh(removed)
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert removed.state == Status.SKIPPED and removed.check_suite_id == new.id


# ---------------------------------------------------------------------------- check_suite re-request
def test_rerun_command_copies_the_suite_without_linking_the_plan(session, ready, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    status = CreateExecutionByCommand.run(
        session, w.plan.id, w.suite.id, payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)
    )
    assert status[0] == 200
    new = session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()
    assert new.id != w.suite.id and new.commit_sha_ref == w.suite.commit_sha_ref and new.re_run and new.plan_id is None
    assert new.bamboo_ci_ref == "PROJ-PLAN-1" and new.cancelled_previous_check_suite_id == w.suite.id
    assert "PROJ-PLAN-77" in bamboo.stopped
    assert session.scalars(select(AuditRetry)).one().retry_type == "full"


def test_rerun_command_with_unknown_suite(session, ready) -> None:
    assert CreateExecutionByCommand.run(session, 1, 9999, {})[0] == 404


def test_rerun_does_not_create_stages_when_bamboo_rejects_the_plan(session, ready, bamboo, github) -> None:
    w = f.World(session)
    github.commits = [[{"sha": "c" * 40}]]
    bamboo.submit_status, bamboo.submit_text = 404, "Plan not found"
    stages_before = len(session.scalars(select(Stage)).all())
    status = CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    assert status == (404, "Failed to create CI Plan")
    assert len(session.scalars(select(Stage)).all()) == stages_before
    cmd = CreateExecutionByCommand.run(
        session, w.plan.id, w.suite.id, payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)
    )
    assert cmd == (404, "Failed to create CI Plan")
    assert len(session.scalars(select(Stage)).all()) == stages_before


def test_jobs_are_awaited_while_bamboo_expands_the_plan(clients, bamboo, settings, monkeypatch) -> None:
    from netdef_ci.services.common import wait_for_running_jobs

    monkeypatch.setattr(settings, "running_plan_wait_seconds", 60)
    answers = iter([[], [], JOBS])
    bamboo.running_plan = lambda _ref: next(answers)
    sleeps: list[float] = []
    assert wait_for_running_jobs("PROJ-PLAN-1", sleep=sleeps.append) == JOBS
    assert sleeps == [settings.running_plan_poll_seconds] * 2


def test_waiting_for_jobs_is_bounded(clients, bamboo, settings) -> None:
    from netdef_ci.services.common import wait_for_running_jobs

    bamboo.default_jobs = []
    assert wait_for_running_jobs("PROJ-PLAN-1", sleep=lambda _s: None) == []  # wait is 0 s in the tests


def test_rerun_without_listed_jobs_creates_no_stages(session, ready, bamboo, github) -> None:
    w = f.World(session)
    github.commits = [[{"sha": "c" * 40}]]
    bamboo.default_jobs = []
    before = len(session.scalars(select(Stage)).all())
    CreateExecutionByComment.run(
        session, w.pr.id, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id), w.plan.id
    )
    assert len(session.scalars(select(Stage)).all()) == before
