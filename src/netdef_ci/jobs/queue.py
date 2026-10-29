#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/queue.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""PostgreSQL-backed job queue: `run_at` scheduling, named/numeric queues, lock expiry, bounded attempts with
back-off (`5 + attempts**4` seconds) and removal of permanently failed jobs.

Idle workers do not poll: they sleep until the next `run_at` of their queues (at most JOB_SLEEP_DELAY_SECONDS) and
are woken earlier by a PostgreSQL `NOTIFY` sent with every enqueued job."""

from __future__ import annotations

import os
import signal
import socket
import threading
import time
import traceback
from collections.abc import Callable, Sequence
from contextlib import contextmanager, suppress
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, func, or_, select, text
from sqlalchemy.orm import Session

from netdef_ci.config import Settings, get_settings
from netdef_ci.db import get_engine, session_factory, utcnow
from netdef_ci.jobs.registry import HANDLERS
from netdef_ci.logs import Log
from netdef_ci.models import Job

NOTIFY_CHANNEL = "netdef_jobs"
MIN_IDLE_WAIT_SECONDS = 0.05


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
    commit: bool = True,
) -> Job:
    """`commit=False` leaves the job (and its NOTIFY) to the caller's commit, in the same transaction as its other
    changes."""
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
    if session.get_bind().dialect.name == "postgresql":
        # Delivered at commit to the idle workers of this queue (see `_Listener`), with the time the job is due.
        due = job.run_at.replace(tzinfo=UTC).timestamp()
        session.execute(
            text("SELECT pg_notify(:channel, :payload)"),
            {"channel": NOTIFY_CHANNEL, "payload": f"{job.queue or ''}|{due:.3f}"},
        )
    if commit:
        session.commit()
    return job


def execution_queue(name: str, github_pr_id: int | None) -> str:
    """Queue of a flow that starts Bamboo plans for one pull request (see EXECUTION_QUEUE_PARTITIONS)."""
    partitions = get_settings().execution_queue_partitions
    return name if partitions <= 1 else f"{name}_{(github_pr_id or 0) % partitions}"


def replace_pending(
    session: Session,
    handler: str,
    dedupe_key: str,
    args: Sequence[Any],
    *,
    queue: str | int,
    delay_seconds: float,
    commit: bool = True,
) -> Job:
    """Debounce: drop jobs of the same kind/key that did not start yet and schedule a new one (one transaction)."""
    session.execute(
        delete(Job).where(
            Job.handler == handler,
            Job.queue == str(queue),
            Job.dedupe_key == dedupe_key,
            Job.locked_at.is_(None),
        )
    )
    return enqueue(
        session, handler, args, queue=queue, delay_seconds=delay_seconds, dedupe_key=dedupe_key, commit=commit
    )


class JobTimeoutError(Exception):
    pass


@contextmanager
def _time_limit(seconds: int) -> Any:
    """Abort the running job after `seconds`. Only possible in the main thread."""
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


def parse_notification(payload: str) -> tuple[str, float]:
    """`<queue>|<run_at epoch>` -> (queue, seconds until due). A payload without a time counts as due now."""
    queue_name, separator, due = payload.rpartition("|")
    if not separator:
        return payload, 0.0
    try:
        return queue_name, float(due) - time.time()
    except ValueError:
        return queue_name, 0.0


class _Listener:
    """`LISTEN` on a dedicated connection (PostgreSQL only). Any failure drops the connection and the worker falls
    back to sleeping until its next job is due; the next wait reconnects."""

    def __init__(self, log: Log) -> None:
        self.log = log
        self._raw: Any = None

    def _connection(self) -> Any:
        if self._raw is None:
            raw = get_engine().raw_connection()
            conn: Any = raw.driver_connection  # psycopg.Connection
            conn.autocommit = True
            conn.execute(f"LISTEN {NOTIFY_CHANNEL}")
            self._raw = raw
        return self._raw.driver_connection

    def wait(self, seconds: float, queues: list[str] | None, stop: threading.Event) -> None:
        """Return after `seconds`, when a job of one of `queues` (None: any) is due, or when `stop` is set.

        A notification for a job due later (most jobs: debounced status updates, delayed creations) does not wake
        the worker; it only moves the end of this wait to that job's `run_at`, without a query."""
        deadline = time.monotonic() + seconds
        try:
            conn = self._connection()
            while not stop.is_set() and (remaining := deadline - time.monotonic()) > 0:
                # Short slices keep a stop request (SIGTERM) responsive; waiting on the socket costs no query.
                for notify in conn.notifies(timeout=min(remaining, 0.5)):
                    queue_name, due_in = parse_notification(notify.payload)
                    if queues is not None and queue_name not in queues:
                        continue
                    if due_in <= 0:
                        return
                    if time.monotonic() + due_in < deadline:
                        deadline = time.monotonic() + due_in
                        break  # recompute the slice for the earlier deadline
        except Exception as error:
            self.log.warning("Job notifications unavailable (%s: %s); sleeping instead", type(error).__name__, error)
            self.close()
            stop.wait(max(deadline - time.monotonic(), 0))

    def close(self) -> None:
        if self._raw is not None:
            with suppress(Exception):  # an already broken connection has nothing left to release
                self._raw.invalidate()  # it is in LISTEN/autocommit mode: never return it to the pool
            self._raw = None


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
                session.delete(job)  # exhausted jobs are removed
            else:
                job.run_at = utcnow() + timedelta(seconds=5 + job.attempts**4)
                job.locked_at = None
                job.locked_by = None
            session.commit()

    def idle_seconds(self) -> float:
        """How long an idle worker may sleep: until the next job of its queues is due, at most
        JOB_SLEEP_DELAY_SECONDS (which also bounds the wait for a lock that expires)."""
        limit = self.settings.job_sleep_delay_seconds
        stmt = select(func.min(Job.run_at)).where(Job.failed_at.is_(None), Job.locked_at.is_(None))
        if self.queues is not None:
            stmt = stmt.where(Job.queue.in_(self.queues))
        with session_factory()() as session:
            next_run = session.scalar(stmt)
        if next_run is None:
            return limit
        return min(max((next_run - utcnow()).total_seconds(), MIN_IDLE_WAIT_SECONDS), limit)

    def run_forever(self) -> None:
        self.log.info("Worker %s started (queues=%s)", self.name, self.queues or "all")
        listener = _Listener(self.log) if get_engine().dialect.name == "postgresql" else None
        try:
            while not self.stop_event.is_set():
                try:
                    worked = self.run_once()
                    wait = 0.0 if worked else self.idle_seconds()
                except Exception as error:
                    self.log.error("Worker loop error: %s: %s", type(error).__name__, error)
                    wait = self.settings.job_sleep_delay_seconds
                if wait <= 0:
                    continue
                if listener is not None:
                    listener.wait(wait, self.queues, self.stop_event)
                else:
                    self.stop_event.wait(wait)
        finally:
            if listener is not None:
                listener.close()
        self.log.info("Worker %s stopped", self.name)


def _short(args: list[Any]) -> str:
    text = repr(args)
    return text if len(text) <= 120 else text[:117] + "..."
