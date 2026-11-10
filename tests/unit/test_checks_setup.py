#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_checks_setup.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest
from sqlalchemy import select

from netdef_ci.enums import Status
from netdef_ci.github.build.checks_setup import ChecksSetup
from netdef_ci.models import CheckSuite, CiJob, Job, Stage
from netdef_ci.workers.loader_workers import REGISTERED
from tests import factories as f

JOBS = [
    {"name": "Build job", "job_ref": "PROJ-PLAN-9-BLD", "stage": "Build"},
    {"name": "Tests job", "job_ref": "PROJ-PLAN-9-TST", "stage": "Tests"},
]


@pytest.fixture
def started(session, clients, bamboo):
    """An execution Bamboo started (PROJ-PLAN-9) whose GitHub setup died before creating anything, and the execution
    it replaced (PROJ-PLAN-8, already stopped in Bamboo)."""
    configs = f.default_stage_configs(session)
    pr = f.pull_request(session, number=7)
    plan = f.plan(session, pull_request=pr)
    previous = f.check_suite(session, pr, plan, ref="PROJ-PLAN-8")
    suite = f.check_suite(session, pr, plan, ref="PROJ-PLAN-9")
    bamboo.default_jobs = JOBS
    return suite, plan, configs, previous


def stages_of(session, suite) -> list[Stage]:
    return list(session.scalars(select(Stage).where(Stage.check_suite_id == suite.id).order_by(Stage.id)))


def jobs_of(session, suite) -> list[CiJob]:
    return list(session.scalars(select(CiJob).where(CiJob.check_suite_id == suite.id).order_by(CiJob.id)))


def test_setup_job_is_registered() -> None:
    assert "setup_github_checks" in REGISTERED


def test_setup_job_creates_no_check_suite_and_never_starts_or_stops_bamboo(session, started, bamboo, github) -> None:
    suite, plan, _configs, _previous = started
    assert ChecksSetup.run(session, suite.id, plan.id, [], False) == (200, "Pull Request created")
    assert len(session.scalars(select(CheckSuite)).all()) == 2
    assert bamboo.submissions == [] and bamboo.stopped == []
    assert [(s.name, s.state, s.check_ref is not None) for s in stages_of(session, suite)] == [
        ("Build", Status.QUEUED, True),
        ("Tests", Status.QUEUED, True),
    ]
    assert [j.job_ref for j in jobs_of(session, suite)] == ["PROJ-PLAN-9-BLD", "PROJ-PLAN-9-TST"]
    assert session.scalars(select(Job).where(Job.handler == "timeout_execution")).one().args == [suite.id]


def test_setup_job_resumes_the_same_suite_without_duplicating_rows(session, started, bamboo, github, slack) -> None:
    suite, plan, configs, _previous = started
    build = f.stage(session, suite, configs[0])  # created, but its check run POST failed: check_ref is NULL
    f.job(session, suite, build, "Build job", ref="PROJ-PLAN-9-BLD")
    ChecksSetup.run(session, suite.id, plan.id, [], False)
    stages = stages_of(session, suite)
    assert [s.name for s in stages] == ["Build", "Tests"] and stages[0].id == build.id
    assert all(s.check_ref is not None for s in stages)
    assert [c[0] for c in github.calls_named("create")] == ["[CI] Build", "[CI] Tests"]
    assert [j.job_ref for j in jobs_of(session, suite)] == ["PROJ-PLAN-9-BLD", "PROJ-PLAN-9-TST"]
    assert "started" not in slack.names()  # only the first (in-line) run notifies


def test_setup_job_does_not_create_a_second_check_run_or_timeout(session, started, github) -> None:
    suite, plan, configs, _previous = started
    f.stage(session, suite, configs[0], check_ref="601")
    ChecksSetup.run(session, suite.id, plan.id, [], False)
    ChecksSetup.run(session, suite.id, plan.id, [], False)
    assert [c[0] for c in github.calls_named("create")] == ["[CI] Tests"]
    assert len(session.scalars(select(Job).where(Job.handler == "timeout_execution")).all()) == 1


def test_setup_job_moves_a_start_in_progress_stage_that_stayed_queued(session, started, github) -> None:
    suite, plan, configs, _previous = started
    configs[0].start_in_progress = True
    session.commit()
    build = f.stage(session, suite, configs[0], check_ref="601")
    ChecksSetup.run(session, suite.id, plan.id, [], False)
    session.refresh(build)
    assert build.state == Status.IN_PROGRESS and github.calls_named("in_progress")[0][0] == "601"


def test_setup_job_cancels_the_stopped_execution_and_comments_once(session, started, bamboo, github) -> None:
    suite, plan, configs, old = started
    old_stage = f.stage(session, old, configs[0], status=Status.IN_PROGRESS, check_ref="701")
    ChecksSetup.run(session, suite.id, plan.id, [old.id], False)
    ChecksSetup.run(session, suite.id, plan.id, [old.id], False)
    session.refresh(old_stage)
    assert old_stage.state == Status.CANCELLED and github.calls_named("cancelled") == [("701", {})]
    assert bamboo.cancel_comments == [("PROJ-PLAN-8", "PROJ-PLAN-9")]
    session.refresh(suite)
    assert suite.cancelled_previous_check_suite_id == old.id


def test_setup_job_skips_the_comment_already_sent(session, started, bamboo) -> None:
    suite, plan, _configs, old = started
    suite.cancelled_previous_check_suite_id = old.id
    session.commit()
    ChecksSetup.run(session, suite.id, plan.id, [old.id], False)
    assert bamboo.cancel_comments == []


def test_superseded_setup_job_only_closes_the_stopped_execution(session, started, bamboo, github) -> None:
    suite, plan, configs, previous = started
    open_stage = f.stage(session, previous, configs[0], status=Status.QUEUED, check_ref="801")
    f.check_suite(session, suite.pull_request, plan, ref="PROJ-PLAN-10")  # a newer push already started
    assert ChecksSetup.run(session, suite.id, plan.id, [previous.id], False) == (200, "Superseded")
    assert stages_of(session, suite) == [] and jobs_of(session, suite) == []
    assert github.calls_named("create") == [] and bamboo.cancel_comments == [] and bamboo.stopped == []
    session.refresh(open_stage)
    assert open_stage.state == Status.CANCELLED


def test_newer_suite_that_never_started_does_not_supersede(session, started) -> None:
    suite, plan, _configs, _previous = started
    session.add(
        CheckSuite(pull_request_id=suite.pull_request_id, author="a", commit_sha_ref="8" * 40, base_sha_ref="b" * 40)
    )
    session.commit()
    assert ChecksSetup.run(session, suite.id, plan.id, [], False) == (200, "Pull Request created")


def test_setup_job_for_a_deleted_suite_returns_cleanly(session, started, bamboo, github) -> None:
    _suite, plan, _configs, _previous = started
    assert ChecksSetup.run(session, 999_999, plan.id, [], False) == (404, "Check Suite not found")
    assert github.calls == [] and bamboo.submissions == []


def test_setup_job_failure_raises_so_the_job_is_retried(session, started, github) -> None:
    from netdef_ci.clients.github import GithubNotFound

    suite, plan, _configs, _previous = started
    github.failures["create"] = [GithubNotFound(404, "Not Found")]
    with pytest.raises(GithubNotFound):
        ChecksSetup.run(session, suite.id, plan.id, [], False)
    ChecksSetup.run(session, suite.id, plan.id, [], False)  # the next attempt completes the same suite
    assert all(s.check_ref is not None for s in stages_of(session, suite)) and len(stages_of(session, suite)) == 2


def test_rerun_setup_job_moves_jobs_removed_from_the_plan(session, started, bamboo) -> None:
    suite, plan, _configs, old = started
    old.commit_sha_ref = suite.commit_sha_ref  # a rerun of the same commit
    session.commit()
    removed = f.job(session, old, None, "Removed job", Status.FAILURE, "PROJ-PLAN-8-OLD")
    bamboo.jobs["PROJ-PLAN-8"] = []
    ChecksSetup.run(session, suite.id, plan.id, [], True)
    session.refresh(removed)
    assert removed.state == Status.SKIPPED and removed.check_suite_id == suite.id


def test_slack_failure_on_the_first_run_is_logged_and_never_rescheduled(session, started, slack, github) -> None:
    from netdef_ci.github.build.checks_setup import setup_or_defer
    from netdef_ci.helpers.logs import Log

    suite, plan, _configs, _previous = started

    def broken(_suite) -> None:
        raise RuntimeError("Slack bot down")

    slack.execution_started_notification = broken
    status = setup_or_defer(session, suite, plan, [], rerun=False, queue="create_execution_by_plan", log=Log("t"))
    assert status == (200, "Pull Request created")
    assert len(stages_of(session, suite)) == 2
    assert session.scalars(select(Job).where(Job.handler == "setup_github_checks")).all() == []
