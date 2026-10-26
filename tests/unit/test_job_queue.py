#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_job_queue.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from netdef_ci.db import utcnow
from netdef_ci.jobs import queue
from netdef_ci.jobs.registry import HANDLERS, job_handler
from netdef_ci.models import Job

CALLS: list[tuple] = []


@pytest.fixture(autouse=True)
def handlers():
    CALLS.clear()

    @job_handler("t_ok")
    def ok(*args):
        CALLS.append(args)

    @job_handler("t_fail")
    def fail(*args):
        raise RuntimeError("boom")

    yield
    HANDLERS.pop("t_ok", None)
    HANDLERS.pop("t_fail", None)


def worker(**kw) -> queue.Worker:
    return queue.Worker(use_timeout=False, name="w1", **kw)


def test_runs_due_job_once_and_deletes_it(session) -> None:
    queue.enqueue(session, "t_ok", [1, {"a": 2}], queue=3)
    assert worker().run_once() is True
    assert CALLS == [(1, {"a": 2})]
    assert worker().run_once() is False
    assert session.scalars(select(Job)).all() == []


def test_future_jobs_wait_until_run_at(session) -> None:
    queue.enqueue(session, "t_ok", [], delay_seconds=60)
    assert worker().run_once() is False
    job = session.scalars(select(Job)).one()
    job.run_at = utcnow() - timedelta(seconds=1)
    session.commit()
    assert worker().run_once() is True


def test_order_is_priority_then_run_at_then_id(session) -> None:
    now = utcnow()
    queue.enqueue(session, "t_ok", ["late"], run_at=now - timedelta(seconds=1))
    queue.enqueue(session, "t_ok", ["early"], run_at=now - timedelta(seconds=30))
    queue.enqueue(session, "t_ok", ["urgent"], run_at=now - timedelta(seconds=1), priority=-5)
    w = worker()
    while w.run_once():
        pass
    assert [c[0] for c in CALLS] == ["urgent", "early", "late"]


def test_worker_only_takes_its_queues(session) -> None:
    queue.enqueue(session, "t_ok", ["a"], queue="1")
    queue.enqueue(session, "t_ok", ["b"], queue="2")
    w = worker(queues=["2"])
    assert w.run_once() is True and w.run_once() is False
    assert CALLS == [("b",)]


def test_failed_job_is_rescheduled_with_delayed_job_backoff_then_destroyed(session) -> None:
    queue.enqueue(session, "t_fail", [], max_attempts=3)
    w = worker()
    for attempt in (1, 2):
        before = utcnow()
        assert w.run_once() is True
        session.expire_all()
        job = session.scalars(select(Job)).one()
        assert job.attempts == attempt and "boom" in job.last_error and job.locked_at is None
        assert (
            before + timedelta(seconds=5 + attempt**4 - 1)
            <= job.run_at
            <= before + timedelta(seconds=5 + attempt**4 + 5)
        )
        job.run_at = utcnow()
        session.commit()
    assert w.run_once() is True
    session.expire_all()
    assert session.scalars(select(Job)).all() == []  # destroy_failed_jobs


def test_unknown_handler_counts_as_failure(session) -> None:
    queue.enqueue(session, "missing", [], max_attempts=1)
    assert worker().run_once() is True
    assert session.scalars(select(Job)).all() == []


def test_expired_lock_is_taken_over_but_active_lock_is_not(session, settings) -> None:
    queue.enqueue(session, "t_ok", ["x"])
    job = session.scalars(select(Job)).one()
    job.locked_at, job.locked_by = utcnow(), "other"
    session.commit()
    assert worker().run_once() is False
    job.locked_at = utcnow() - timedelta(seconds=settings.job_max_run_time_seconds + 5)
    session.commit()
    assert worker().run_once() is True


def test_debounce_replaces_only_pending_jobs_of_same_key(session) -> None:
    queue.replace_pending(session, "t_ok", "REF-1", ["REF-1", 1], queue=3, delay_seconds=30)
    queue.replace_pending(session, "t_ok", "REF-2", ["REF-2", 2], queue=3, delay_seconds=30)
    queue.replace_pending(session, "t_ok", "REF-1", ["REF-1", 9], queue=3, delay_seconds=30)
    jobs = session.scalars(select(Job).order_by(Job.id)).all()
    assert [j.args for j in jobs] == [["REF-2", 2], ["REF-1", 9]]
    running = jobs[0]
    running.locked_at = utcnow()
    session.commit()
    queue.replace_pending(session, "t_ok", "REF-2", ["REF-2", 3], queue=3, delay_seconds=30)
    assert session.scalars(select(Job).where(Job.dedupe_key == "REF-2")).all().__len__() == 2  # a running job is kept


def test_timeout_aborts_long_job(session, settings) -> None:
    import time

    @job_handler("t_slow")
    def slow() -> None:
        time.sleep(5)

    try:
        queue.enqueue(session, "t_slow", [], max_attempts=1)
        w = queue.Worker(
            use_timeout=True, name="w", settings=settings.model_copy(update={"job_max_run_time_seconds": 1})
        )
        started = time.monotonic()
        w.run_once()
        assert time.monotonic() - started < 4
        session.expire_all()
        assert session.scalars(select(Job)).all() == []
    finally:
        HANDLERS.pop("t_slow", None)
