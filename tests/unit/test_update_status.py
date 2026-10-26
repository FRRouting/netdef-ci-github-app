#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_update_status.py
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
from netdef_ci.models import Job, TopotestFailure
from netdef_ci.services.update_status import UpdateStatus
from tests import factories as f


def update(session, payload):
    return UpdateStatus(session, payload).update()


def test_unknown_job_is_404(session, clients) -> None:
    assert update(session, {"status": "success", "bamboo_ref": "NOPE-1"}) == (404, "CI JOB not found")
    assert update(session, {"status": "success"}) == (404, "CI JOB not found")


def test_queued_job_ignores_everything_but_in_progress(session, clients) -> None:
    w = f.World(session)
    assert update(session, {"status": "success", "bamboo_ref": w.build_job.job_ref}) == (304, "Not Modified")
    assert update(session, {"status": "failure", "bamboo_ref": w.build_job.job_ref}) == (304, "Not Modified")
    session.refresh(w.build_job)
    assert w.build_job.state == Status.QUEUED


def test_checkout_code_may_finish_without_having_started(session, clients) -> None:
    w = f.World(session)
    w.build_job.name = "Checkout Code"
    session.commit()
    assert update(session, {"status": "success", "bamboo_ref": w.build_job.job_ref}) == (200, "Success")
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SUCCESS


def test_in_progress_job_only_accepts_success_or_failure(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    assert update(session, {"status": "in_progress", "bamboo_ref": w.build_job.job_ref}) == (304, "Not Modified")
    assert update(session, {"status": "queued", "bamboo_ref": w.build_job.job_ref}) == (304, "Not Modified")


def test_start_then_success_records_time_and_debounces_summary(session, clients, settings) -> None:
    w = f.World(session)
    assert update(session, {"status": "in_progress", "bamboo_ref": w.build_job.job_ref}) == (200, "Success")
    assert update(session, {"status": "success", "bamboo_ref": w.build_job.job_ref}) == (200, "Success")
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SUCCESS
    jobs = session.scalars(select(Job).where(Job.handler == "ci_job_status")).all()
    assert len(jobs) == 1  # the in_progress callback's job was replaced (debounce)
    job = jobs[0]
    assert job.queue == str(w.pr.github_pr_id % 10)
    assert job.args == ["PROJ-PLAN-77", w.build_job.id]
    delta = job.run_at - utcnow()
    assert timedelta(seconds=25) < delta <= timedelta(seconds=settings.status_debounce_seconds)


def test_failure_with_reported_tests_stores_them_and_summary(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    payload = {
        "status": "failure",
        "bamboo_ref": w.build_job.job_ref,
        "output": {"summary": "Checkout failed"},
        "failures": [
            {"suite": "s1", "case": "c1", "message": "m1", "execution_time": 3},
            {"suite": "s2", "case": "c2", "message": "m2", "execution_time": 4},
        ],
    }
    assert update(session, payload) == (200, "Success")
    session.refresh(w.build_job)
    assert w.build_job.state == Status.FAILURE and w.build_job.summary == "Checkout failed"
    assert [(t.test_suite, t.test_case) for t in session.scalars(select(TopotestFailure))] == [
        ("s1", "c1"),
        ("s2", "c2"),
    ]
    assert session.scalars(select(Job).where(Job.handler == "fetch_topotest_failures")).all() == []


def test_failure_without_tests_schedules_fetch_in_five_minutes(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    update(session, {"status": "failure", "bamboo_ref": w.build_job.job_ref})
    fetch = session.scalars(select(Job).where(Job.handler == "fetch_topotest_failures")).one()
    assert fetch.args == [w.build_job.id, 1] and fetch.queue == "fetch_topotest_failures"
    assert timedelta(minutes=4, seconds=50) < fetch.run_at - utcnow() <= timedelta(minutes=5)


def test_unrecognised_status_is_handled_as_failure(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    w.build_job.state  # noqa: B018
    # status "failure" is required for an in-progress job, so exercise the else branch through a queued Checkout Code job
    w.build_job.status = Status.QUEUED
    w.build_job.name = "Checkout Code"
    session.commit()
    assert update(session, {"status": "weird", "bamboo_ref": w.build_job.job_ref}) == (200, "Success")
    session.refresh(w.build_job)
    assert w.build_job.state == Status.FAILURE


def test_superseded_execution_does_not_schedule_summary(session, clients) -> None:
    w = f.World(session)
    f.check_suite(session, w.pr, w.plan)  # newer execution of the same plan
    assert update(session, {"status": "in_progress", "bamboo_ref": w.build_job.job_ref}) == (200, "Success")
    assert session.scalars(select(Job)).all() == []


def test_unexpected_errors_become_500(session, clients, github) -> None:
    w = f.World(session)
    w.build_job.check_ref = "900"
    session.commit()

    def explode(*_a, **_k):
        raise RuntimeError("github down")

    github.in_progress = explode
    assert update(session, {"status": "in_progress", "bamboo_ref": w.build_job.job_ref}) == (
        500,
        "Internal Server Error",
    )


@pytest.mark.parametrize("extra", [{}, {"output": {}}])
def test_payload_without_summary_is_tolerated(session, clients, extra) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    assert update(session, {"status": "failure", "bamboo_ref": w.build_job.job_ref, **extra})[0] == 200
