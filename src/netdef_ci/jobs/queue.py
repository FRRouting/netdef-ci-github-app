#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/queue.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""PostgreSQL-backed job queue with Delayed Job semantics: `run_at` scheduling, named/numeric queues, lock expiry,
bounded attempts with the same back-off (`5 + attempts**4` seconds) and removal of permanently failed jobs."""

from __future__ import annotations

import os
import signal
import socket
import threading
import time
import traceback
from collections.abc import Callable, Sequence
from contextlib import contextmanager
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import delete, or_, select
from sqlalchemy.orm import Session

from netdef_ci.config import Settings, get_settings
from netdef_ci.db import session_factory, utcnow
from netdef_ci.jobs.registry import HANDLERS
from netdef_ci.logs import Log
from netdef_ci.models import Job


def enqueue(
    session: Session,
    handler: str,
    args: Sequence[Any] = (),
    *,
    queue: str | int | None = None,
    delay_seconds: float = 0,
    run_at: datetime | None = None,
    max_attempts: int | None = None,
    dedupe_key: str | None = None,
    priority: int = 0,
) -> Job:
    settings = get_settings()
    job = Job(
        handler=handler,
        args=list(args),
        queue=None if queue is None else str(queue),
        run_at=run_at or (utcnow() + timedelta(seconds=delay_seconds)),
        max_attempts=max_attempts or settings.job_max_attempts,
        dedupe_key=dedupe_key,
        priority=priority,
    )
    session.add(job)
    session.commit()
    return job


def replace_pending(
    session: Session, handler: str, dedupe_key: str, args: Sequence[Any], *, queue: str | int, delay_seconds: float
) -> Job:
    """Debounce: drop jobs of the same kind/key that did not start yet and schedule a new one."""
    session.execute(
        delete(Job).where(
            Job.handler == handler,
            Job.queue == str(queue),
            Job.dedupe_key == dedupe_key,
            Job.locked_at.is_(None),
        )
    )
    session.commit()
    return enqueue(session, handler, args, queue=queue, delay_seconds=delay_seconds, dedupe_key=dedupe_key)


class JobTimeoutError(Exception):
    pass


@contextmanager
def _time_limit(seconds: int) -> Any:
    """Abort the running job after `seconds` (Delayed::Worker.max_run_time). Only possible in the main thread."""
    if threading.current_thread() is not threading.main_thread() or not hasattr(signal, "setitimer"):
        yield
        return

    def on_alarm(signum: int, frame: Any) -> None:
        raise JobTimeoutError(f"job exceeded max_run_time of {seconds}s")

    previous = signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


class Worker:
    def __init__(
        self,
        *,
        queues: Sequence[str] | None = None,
        settings: Settings | None = None,
        name: str | None = None,
        sleep: Callable[[float], None] = time.sleep,
        use_timeout: bool = True,
    ) -> None:
        self.settings = settings or get_settings()
        self.queues = [str(q) for q in queues] if queues else None
        self.name = name or f"{socket.gethostname()}:{os.getpid()}"
        self._sleep = sleep
        self._use_timeout = use_timeout
        self.log = Log("jobs")
        self.stop_event = threading.Event()

    # -------------------------------------------------------------------------
    def reserve(self, session: Session) -> Job | None:
        now = utcnow()
        lock_limit = now - timedelta(seconds=self.settings.job_max_run_time_seconds)
        stmt = select(Job).where(
            Job.failed_at.is_(None),
            Job.run_at <= now,
            or_(Job.locked_at.is_(None), Job.locked_at < lock_limit),
        )
        if self.queues is not None:
            stmt = stmt.where(Job.queue.in_(self.queues))
        job = session.scalars(
            stmt.order_by(Job.priority, Job.run_at, Job.id).limit(1).with_for_update(skip_locked=True)
        ).first()
        if job is None:
            session.rollback()
            return None
        job.locked_at = now
        job.locked_by = self.name
        session.commit()
        return job

    def run_once(self) -> bool:
        """Reserve and run one job; returns False when nothing was available."""
        with session_factory()() as session:
            job = self.reserve(session)
            if job is None:
                return False
            job_id, handler_name, args = job.id, job.handler, list(job.args)
        self._execute(job_id, handler_name, args)
        return True

    def _execute(self, job_id: int, handler_name: str, args: list[Any]) -> None:
        handler = HANDLERS.get(handler_name)
        try:
            if handler is None:
                raise LookupError(f"no handler registered for {handler_name!r}")
            self.log.info("Running job %s %s%s", job_id, handler_name, _short(args))
            if self._use_timeout:
                with _time_limit(self.settings.job_max_run_time_seconds):
                    handler(*args)
            else:
                handler(*args)
        except BaseException as error:
            self._failed(job_id, handler_name, error)
            if isinstance(error, KeyboardInterrupt | SystemExit):
                raise
            return
        with session_factory()() as session:
            session.execute(delete(Job).where(Job.id == job_id))
            session.commit()

    def _failed(self, job_id: int, handler_name: str, error: BaseException) -> None:
        text = "".join(traceback.format_exception(error))[-4000:]
        self.log.error("Job %s (%s) failed: %s: %s", job_id, handler_name, type(error).__name__, error)
        with session_factory()() as session:
            job = session.get(Job, job_id)
            if job is None:
                return
            job.attempts += 1
            job.last_error = text
            if job.attempts >= job.max_attempts:
                self.log.error("Job %s (%s) exhausted %s attempts; removing it", job_id, handler_name, job.max_attempts)
                session.delete(job)  # Delayed::Worker.destroy_failed_jobs = true
            else:
                job.run_at = utcnow() + timedelta(seconds=5 + job.attempts**4)
                job.locked_at = None
                job.locked_by = None
            session.commit()

    def run_forever(self) -> None:
        self.log.info("Worker %s started (queues=%s)", self.name, self.queues or "all")
        while not self.stop_event.is_set():
            try:
                worked = self.run_once()
            except Exception as error:
                self.log.error("Worker loop error: %s: %s", type(error).__name__, error)
                worked = False
            if not worked:
                self.stop_event.wait(self.settings.job_sleep_delay_seconds)
        self.log.info("Worker %s stopped", self.name)


def _short(args: list[Any]) -> str:
    text = repr(args)
    return text if len(text) <= 120 else text[:117] + "..."
