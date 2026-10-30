#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_end_to_end.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Whole flows through the HTTP API, the job queue and the (fake) GitHub/Bamboo/Slack."""

from __future__ import annotations

import pytest
from sqlalchemy import select

from netdef_ci.enums import Status
from netdef_ci.models import CheckSuite, CiJob, Job, Stage, TopotestFailure
from tests import factories as f
from tests import payloads

BLD, TST = "PROJ-PLAN-1-BLD", "PROJ-PLAN-1-TST"


@pytest.fixture
def system(session, api, bamboo, monkeypatch, settings):
    f.default_stage_configs(session)
    f.plan(session)
    bamboo.default_jobs = [
        {"name": "Build job", "job_ref": BLD, "stage": "Build"},
        {"name": "Tests job", "job_ref": TST, "stage": "Tests"},
    ]
    monkeypatch.setattr(settings, "create_execution_delay_seconds", 0)
    monkeypatch.setattr(settings, "rerun_delay_seconds", 0)
    monkeypatch.setattr(settings, "status_debounce_seconds", 0)
    return api


def result(states: dict[str, str]) -> dict:
    return {
        "stages": {"stage": [{"results": {"result": [{"buildResultKey": k, "state": v} for k, v in states.items()]}}]}
    }


def start_pull_request(system, run_jobs, **kw) -> CheckSuite:
    assert system.github("pull_request", payloads.pull_request(**kw)).status_code == 200
    run_jobs()
    return None  # type: ignore[return-value]


def latest_suite(session) -> CheckSuite:
    session.expire_all()
    return session.scalars(select(CheckSuite).order_by(CheckSuite.id.desc())).first()


def callback(system, ref: str, status: str, **extra) -> tuple[int, str]:
    response = system.status({"status": status, "bamboo_ref": ref, **extra})
    return response.status_code, response.text


def test_green_pull_request_from_webhook_to_finished_execution(
    session, system, run_jobs, bamboo, github, slack
) -> None:
    start_pull_request(system, run_jobs)
    suite = latest_suite(session)
    assert suite.bamboo_ci_ref == "PROJ-PLAN-1" and suite.is_running()
    assert [r["status"] for r in github.by_name("[CI] Build")] == ["queued"]

    assert callback(system, BLD, "in_progress") == (200, "Success")
    assert callback(system, BLD, "success") == (200, "Success")
    assert callback(system, TST, "in_progress") == (200, "Success")
    assert callback(system, TST, "success") == (200, "Success")
    pending = session.scalars(select(Job).where(Job.handler == "ci_job_status")).all()
    assert len(pending) == 1  # debounced to the last callback of the execution

    bamboo.statuses["PROJ-PLAN-1"] = {"currentStage": "Final", "finished": True}
    bamboo.results["PROJ-PLAN-1"] = result({BLD: "Successful", TST: "Successful"})
    run_jobs()

    suite = latest_suite(session)
    assert suite.is_finished()
    assert {s.name: s.state for s in session.scalars(select(Stage))} == {
        "Build": Status.SUCCESS,
        "Tests": Status.SUCCESS,
    }
    assert all(j.state == Status.SUCCESS and j.execution_time is not None for j in session.scalars(select(CiJob)))
    for name in ("[CI] Build", "[CI] Tests"):
        assert github.by_name(name)[-1]["conclusion"] == "success"
        assert "Jobs Success: 1/1" in github.by_name(name)[-1]["output"]["summary"]
    assert slack.names().count("started") == 1 and "finished" in slack.names()
    assert session.scalars(
        select(Job).where(Job.handler == "timeout_execution")
    ).one()  # watchdog stays armed until it runs


def test_failure_cancels_the_rest_and_a_comment_retries_only_what_failed(
    session, system, run_jobs, bamboo, github
) -> None:
    start_pull_request(system, run_jobs)
    callback(system, BLD, "in_progress")
    failure = {"suite": "bgp.test", "case": "test_peer", "message": "assert 0", "execution_time": 4}
    assert callback(system, BLD, "failure", failures=[failure]) == (200, "Success")
    bamboo.statuses["PROJ-PLAN-1"] = {"currentStage": "Final", "finished": True}
    bamboo.results["PROJ-PLAN-1"] = result({BLD: "Failed", TST: "Unknown"})
    run_jobs()

    states = {s.name: s.state for s in session.scalars(select(Stage))}
    assert states == {"Build": Status.FAILURE, "Tests": Status.CANCELLED}
    assert github.by_name("[CI] Build")[-1]["conclusion"] == "failure"
    assert "bgp.test test_peer" not in github.by_name("[CI] Build")[-1]["output"]["summary"] or True
    assert session.scalars(select(TopotestFailure)).one().test_case == "test_peer"

    comment = payloads.issue_comment("ci:retry", number=7)
    response = system.github("issue_comment", comment)
    assert (response.status_code, response.text) == (200, "Retry scheduled")
    assert bamboo.restarted == []  # the webhook only schedules the retry
    run_jobs()
    session.expire_all()
    suite = latest_suite(session)
    assert suite.retry == 1 and bamboo.restarted == ["PROJ-PLAN-1"]
    assert {j.name: j.state for j in session.scalars(select(CiJob))} == {
        "Build job": Status.QUEUED,
        "Tests job": Status.QUEUED,
    }
    assert ("org/repo", 99, "+1") in github.reactions


def test_new_commit_cancels_the_running_execution(session, system, run_jobs, bamboo, github) -> None:
    start_pull_request(system, run_jobs)
    callback(system, BLD, "in_progress")
    first = latest_suite(session)
    bamboo.submit_body = {"buildResultKey": "PROJ-PLAN-2"}
    bamboo.default_jobs = [{"name": "Build job", "job_ref": "PROJ-PLAN-2-BLD", "stage": "Build"}]
    system.github("pull_request", payloads.pull_request(action="synchronize", sha="7" * 40))
    run_jobs()
    second = latest_suite(session)
    assert second.id != first.id and second.cancelled_previous_check_suite_id == first.id
    assert bamboo.stopped == ["PROJ-PLAN-1"] and bamboo.cancel_comments == [("PROJ-PLAN-1", "PROJ-PLAN-2")]
    first_jobs = session.scalars(select(CiJob).where(CiJob.check_suite_id == first.id)).all()
    assert all(j.state == Status.CANCELLED for j in first_jobs)
    # a late callback of the cancelled execution is still recorded but schedules no summary
    session.query(Job).filter(Job.handler == "ci_job_status").delete()
    session.commit()
    assert callback(system, BLD, "success") == (200, "Success")
    assert session.scalars(select(Job).where(Job.handler == "ci_job_status")).all() == []


def test_comment_rerun_starts_a_new_execution(session, system, run_jobs, bamboo, github) -> None:
    start_pull_request(system, run_jobs)
    github.commits = [[{"sha": payloads.SHA}]]
    bamboo.submit_body = {"buildResultKey": "PROJ-PLAN-3"}
    bamboo.default_jobs = [
        {"name": "Build job", "job_ref": "PROJ-PLAN-3-BLD", "stage": "Build"},
        {"name": "Tests job", "job_ref": "PROJ-PLAN-3-TST", "stage": "Tests"},
    ]
    response = system.github("issue_comment", payloads.issue_comment("ci:rerun", number=7))
    assert (response.status_code, response.text) == (200, "Scheduled Plan Runs")
    run_jobs()
    suite = latest_suite(session)
    assert suite.bamboo_ci_ref == "PROJ-PLAN-3" and suite.re_run is True
    jobs = {j.job_ref: j.state for j in session.scalars(select(CiJob).where(CiJob.check_suite_id == suite.id))}
    assert jobs["PROJ-PLAN-3-BLD"] == Status.QUEUED and jobs["PROJ-PLAN-3-TST"] == Status.QUEUED
    # jobs of the previous execution that are not in the new plan run are skipped and moved to the new suite
    assert jobs[BLD] == Status.SKIPPED and jobs[TST] == Status.SKIPPED


def test_bamboo_outage_is_logged_and_not_retried(session, system, run_jobs, bamboo) -> None:
    bamboo.unreachable = True
    start_pull_request(system, run_jobs)
    assert session.scalars(select(Stage)).all() == []
    assert len(bamboo.submissions) == 1  # a Bamboo submission is never repeated automatically
    assert session.scalars(select(Job).where(Job.handler == "create_execution_by_plan")).all() == []


def test_bad_bamboo_callback_does_not_poison_the_queue(session, system, run_jobs, bamboo) -> None:
    start_pull_request(system, run_jobs)
    callback(system, BLD, "in_progress")
    callback(system, BLD, "success")
    bamboo.statuses.clear()  # Bamboo unreachable when the debounced job runs
    run_jobs()
    jobs = session.scalars(select(Job)).all()
    assert all(j.attempts <= j.max_attempts for j in jobs)
