#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_rerun_retry.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest
from sqlalchemy import select

from netdef_ci.enums import Status
from netdef_ci.github.re_run.command import ReRunCommand
from netdef_ci.github.re_run.comment import ReRunComment
from netdef_ci.github.retry.command import RetryCommand
from netdef_ci.github.retry.comment import RetryComment
from netdef_ci.models import AuditRetry, Job, PullRequestSubscription
from tests import factories as f
from tests import payloads


# ---------------------------------------------------------------------------- ci:rerun (comment)
def test_rerun_comment_requires_a_created_rerun_command(session, clients) -> None:
    assert ReRunComment(session, {}).start() == (422, "Payload can not be blank")
    assert ReRunComment(session, payloads.issue_comment("hello")).start() == (404, "Action not found")
    assert ReRunComment(session, payloads.issue_comment("ci:rerun", action="edited")).start() == (
        404,
        "Action not found",
    )


def test_rerun_comment_needs_a_known_pr_with_executions(session, clients) -> None:
    assert ReRunComment(session, payloads.issue_comment("ci:rerun")).start() == (404, "Pull Request not found")
    pr = f.pull_request(session, number=7)
    assert ReRunComment(session, payloads.issue_comment("ci:rerun")).start() == (404, "Can not rerun a new PullRequest")
    assert pr


def test_rerun_comment_reacts_and_schedules_one_job_per_plan(session, clients, github) -> None:
    w = f.World(session)
    f.plan(session, name="second", bamboo="PROJ-B", pull_request=w.pr)
    payload = payloads.issue_comment("Please CI:RERUN #abc", number=w.pr.github_pr_id)
    assert ReRunComment(session, payload).start() == (200, "Scheduled Plan Runs")
    assert github.reactions == [("org/repo", 99, "rocket")]  # swapped for +1 once Bamboo receives the plan
    jobs = session.scalars(select(Job).order_by(Job.id)).all()
    assert [(j.handler, j.queue, j.max_attempts) for j in jobs] == [
        ("create_execution_by_comment", "create_execution_by_comment", 1)
    ] * 2
    assert all(j.args[0] == w.pr.id and j.args[1] == payload and j.args[3] == 4242 for j in jobs)


def test_rerun_comment_falls_back_to_repository_plans_and_ignores_reaction_errors(session, clients, github) -> None:
    w = f.World(session)
    w.plan.pull_request_id = None  # the plan was "stolen" by a newer PR
    session.commit()
    github.fail_reactions = True
    assert ReRunComment(session, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id)).start()[0] == 200
    assert session.scalars(select(Job)).one().args[2:] == [w.plan.id, None]  # no rocket to remove later


def test_rerun_comment_does_not_cross_repositories(session, clients) -> None:
    f.World(session)
    other = f.pull_request(session, number=7, repo="other/repo")
    f.check_suite(session, other)
    payload = payloads.issue_comment("ci:rerun", number=7, repo="other/repo")
    assert ReRunComment(session, payload).start()[0] == 200  # resolved the PR of the right repository


# ---------------------------------------------------------------------------- check_suite rerequested
def test_rerun_command_errors(session, clients) -> None:
    assert ReRunCommand(session, {}).start() == (422, "Payload can not be blank")
    assert ReRunCommand(session, payloads.check_suite("f" * 40)).start() == (404, "Failed to fetch a check suite")


def test_rerun_command_schedules_per_plan(session, clients) -> None:
    w = f.World(session)
    assert ReRunCommand(session, payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)).start() == (
        200,
        "Scheduled Plan Runs",
    )
    job = session.scalars(select(Job)).one()
    assert (job.handler, job.queue, job.max_attempts) == (
        "create_execution_by_command",
        "create_execution_by_command",
        1,
    )
    assert job.args[:2] == [w.plan.id, w.suite.id]


# ---------------------------------------------------------------------------- retry (check_run re-request)
def finished_world(session, **kw):
    w = f.World(session, statuses=(Status.SUCCESS, Status.FAILURE))
    return w


def test_retry_command_stage_lookup_and_guards(session, clients) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.QUEUED))
    assert RetryCommand(session, {}).start() == (422, "Payload can not be blank")
    assert RetryCommand(session, payloads.check_run(None)).start() == (404, "Stage not found")
    assert RetryCommand(session, payloads.check_run(31337)).start() == (404, "Stage not found")
    assert RetryCommand(session, payloads.check_run(int(w.tests_stage.check_ref))).start() == (
        406,
        "Already enqueued this execution",
    )


def test_partial_retry_requeues_failed_work_and_restarts_bamboo(session, clients, bamboo, github, slack) -> None:
    w = finished_world(session)
    bamboo.jobs["PROJ-PLAN-77"] = [
        {"name": "Tests job", "job_ref": "PROJ-PLAN-77-TST", "stage": "Tests"},
        {"name": "Build job", "job_ref": "PROJ-PLAN-77-BLD", "stage": "Build"},
    ]
    result = RetryCommand(session, payloads.check_run(int(w.tests_stage.check_ref))).start()
    assert result == (200, "Retrying failure jobs")
    for obj in (w.suite, w.tests_job, w.build_job, w.tests_stage, w.build_stage):
        session.refresh(obj)
    assert w.suite.retry == 1 and w.tests_job.retry == 1 and w.tests_job.state == Status.QUEUED
    assert w.build_job.state == Status.SUCCESS and w.build_stage.state == Status.SUCCESS  # untouched
    assert w.tests_stage.state == Status.QUEUED
    audit = session.scalars(select(AuditRetry)).one()
    assert audit.retry_type == "partial" and [j.id for j in audit.ci_jobs] == [w.tests_job.id]
    assert bamboo.stopped == ["PROJ-PLAN-77"] and bamboo.restarted == ["PROJ-PLAN-77"]
    assert "started" in slack.names()


def test_retry_is_refused_while_the_execution_is_still_running(session, clients, github, slack) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.IN_PROGRESS))
    w.tests_stage.status = Status.FAILURE  # the clicked stage failed, but another one is running
    w.build_stage.status = Status.IN_PROGRESS
    session.commit()
    github.check_runs[502] = {"id": 502, "name": "[CI] Tests", "output": {"title": "T", "summary": "S"}}
    session.add(
        PullRequestSubscription(slack_user_id="U1", rule="notify", target=str(w.pr.github_pr_id), notification="errors")
    )
    session.commit()
    code, body = RetryCommand(session, payloads.check_run(502)).start()
    assert (code, body) == (406, "partial rerun refused")
    session.refresh(w.tests_stage)
    assert w.tests_stage.state == Status.FAILURE
    assert github.check_runs[int(w.tests_stage.check_ref)]["output"] == {"title": "T", "summary": "S"}
    assert slack.names().count("invalid_rerun_dm") == 1


# ---------------------------------------------------------------------------- ci:retry (comment)
def test_retry_comment_picks_the_first_failed_stage_and_reacts(session, clients, bamboo, github) -> None:
    w = finished_world(session)
    code, body = RetryComment(session, payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)).start()
    assert (code, body) == (200, "Retrying failure jobs")
    assert ("org/repo", 99, "+1") in github.reactions and bamboo.restarted


def test_retry_comment_without_failed_stage_reacts_with_thumbs_down(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    assert RetryComment(session, payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)).start() == (
        404,
        "Stage not found",
    )
    assert github.reactions == [("org/repo", 99, "-1")]


def test_retry_comment_for_unknown_pr(session, clients, github) -> None:
    assert RetryComment(session, payloads.issue_comment("ci:retry", number=12345)).start() == (404, "Stage not found")
    assert github.reactions == []  # no suite to authenticate against, nothing to react to


@pytest.mark.parametrize("failing", [True, False])
def test_reaction_failures_do_not_break_retry(session, clients, github, failing) -> None:
    w = finished_world(session)
    github.fail_reactions = failing
    assert RetryComment(session, payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)).start()[0] == 200


# ---------------------------------------------------------------------------- retry scheduled from the webhook
def test_retry_comment_schedules_the_job_and_the_job_reacts(session, clients, bamboo, github) -> None:
    from netdef_ci.workers import retry_execution as retry

    w = finished_world(session)
    payload = payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)
    assert RetryComment(session, payload).schedule() == (200, "Retry scheduled")
    job = session.scalars(select(Job).where(Job.handler == "retry_execution")).one()
    assert job.args == ["comment", payload] and job.max_attempts == 1
    assert github.reactions == [] and bamboo.restarted == []  # nothing slow in the webhook
    assert retry.run(session, *job.args) == (200, "Retrying failure jobs")
    assert ("org/repo", 99, "+1") in github.reactions and bamboo.restarted == ["PROJ-PLAN-77"]


def test_retry_comment_refused_by_the_webhook_reacts_at_once(session, clients, github) -> None:
    w = f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))
    assert RetryComment(session, payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)).schedule() == (
        404,
        "Stage not found",
    )
    assert github.reactions == [("org/repo", 99, "-1")]
    assert session.scalars(select(Job)).all() == []


def test_retry_job_for_a_stage_that_disappeared(session, clients) -> None:
    from netdef_ci.workers import retry_execution as retry

    assert retry.run(session, "command", payloads.check_run(31337)) == (404, "Stage not found")


# ---------------------------------------------------------------------------- bursts of ci:retry / ci:rerun
BUSY = (409, "Another ci:retry/ci:rerun is in progress for this pull request")
RECENT = (409, "A ci:retry/ci:rerun started moments ago for this pull request")


def test_burst_of_retry_requests_stops_and_restarts_bamboo_once(session, clients, bamboo, github) -> None:
    """FRR-PULLREQ3-24017: three retries of one suite within 2 s; the later ones stopped the build the first restarted."""
    from netdef_ci.workers import retry_execution as retry

    w = finished_world(session)
    first = payloads.check_run(int(w.tests_stage.check_ref))
    assert RetryCommand(session, first).schedule() == (200, "Retry scheduled")
    comment = payloads.issue_comment("ci:retry", number=w.pr.github_pr_id)
    assert RetryComment(session, comment).schedule() == BUSY
    assert RetryCommand(session, first).schedule() == BUSY
    assert github.reactions == [("org/repo", 99, "-1")]  # the refused comment knows nothing was started
    job = session.scalars(select(Job).where(Job.handler == "retry_execution")).one()
    assert (job.args, job.max_attempts, job.dedupe_key) == (["command", first], 1, f"ci-command:{w.pr.id}")
    assert retry.run(session, *job.args) == (200, "Retrying failure jobs")
    session.delete(job)  # what the worker does with a finished job
    session.commit()
    for stage in (w.tests_stage, w.build_stage):  # the restarted build failed again right away
        stage.status = Status.FAILURE
    session.commit()
    session.refresh(w.tests_stage)  # the retry created a new check run for the stage
    assert RetryCommand(session, payloads.check_run(int(w.tests_stage.check_ref))).schedule() == RECENT
    assert bamboo.stopped == ["PROJ-PLAN-77"] and bamboo.restarted == ["PROJ-PLAN-77"]


def test_burst_of_rerun_requests_starts_one_execution_per_plan(session, clients, github) -> None:
    w = f.World(session)
    f.plan(session, name="second", bamboo="PROJ-B", pull_request=w.pr)
    comment = payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id)
    assert ReRunComment(session, comment).start() == (200, "Scheduled Plan Runs")
    assert (
        ReRunComment(session, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id, comment_id=100)).start()
        == BUSY
    )
    checks_ui = payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)
    assert ReRunCommand(session, checks_ui).start() == BUSY
    assert github.reactions == [("org/repo", 99, "rocket"), ("org/repo", 100, "-1")]
    jobs = session.scalars(select(Job).order_by(Job.id)).all()
    assert [(j.handler, j.dedupe_key) for j in jobs] == [("create_execution_by_comment", f"ci-command:{w.pr.id}")] * 2


def test_retry_and_rerun_of_one_pull_request_exclude_each_other(session, clients, github) -> None:
    w = finished_world(session)
    assert ReRunComment(session, payloads.issue_comment("ci:rerun", number=w.pr.github_pr_id)).start()[0] == 200
    assert RetryCommand(session, payloads.check_run(int(w.tests_stage.check_ref))).schedule() == BUSY


def test_rerun_right_after_a_rerun_started_is_refused_unless_the_cooldown_is_off(
    session, clients, settings, monkeypatch
) -> None:
    w = f.World(session)
    session.add(AuditRetry(check_suite_id=w.suite.id, retry_type="full"))
    session.commit()
    checks_ui = payloads.check_suite(w.suite.commit_sha_ref, number=w.pr.github_pr_id)
    assert ReRunCommand(session, checks_ui).start() == RECENT
    monkeypatch.setattr(settings, "ci_command_cooldown_seconds", 0)
    assert ReRunCommand(session, checks_ui).start() == (200, "Scheduled Plan Runs")


def test_retry_job_decides_from_the_state_after_taking_the_lock(session, clients, bamboo, monkeypatch) -> None:
    from contextlib import contextmanager

    from sqlalchemy import update

    from netdef_ci.models import Stage
    from netdef_ci.workers import retry_execution as retry

    w = finished_world(session)

    @contextmanager
    def lock_released_after_another_retry(pull_request_id):
        # Another worker retried this suite while this job waited for the lock.
        session.execute(
            update(Stage).where(Stage.id == w.tests_stage.id).values(status=Status.QUEUED),
            execution_options={"synchronize_session": False},
        )
        session.commit()
        yield

    monkeypatch.setattr(retry, "pull_request_lock", lock_released_after_another_retry)
    payload = payloads.check_run(int(w.tests_stage.check_ref))
    assert retry.run(session, "command", payload) == (406, "Already enqueued this execution")
    assert bamboo.stopped == [] and bamboo.restarted == []
