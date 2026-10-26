#  SPDX-License-Identifier: BSD-2-Clause
#
#  metrics.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Prometheus metrics. Counters and
histograms are shared by all processes (web + workers) through prometheus_client's multiprocess mode, while
database-derived gauges are produced at scrape time by `DatabaseCollector`."""

from __future__ import annotations

import os
import re
import time
from collections.abc import Callable, Iterable
from datetime import timedelta
from pathlib import Path
from typing import Any

from netdef_ci.config import get_settings

_settings = get_settings()
os.environ.setdefault("PROMETHEUS_MULTIPROC_DIR", _settings.prometheus_multiproc_dir)
Path(os.environ["PROMETHEUS_MULTIPROC_DIR"]).mkdir(parents=True, exist_ok=True)

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, generate_latest  # noqa: E402
from prometheus_client.core import GaugeMetricFamily  # noqa: E402
from prometheus_client.multiprocess import MultiProcessCollector  # noqa: E402

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests handled by the app, by method, route pattern and status code",
    ["method", "path", "status"],
)
HTTP_REQUEST_DURATION = Histogram(
    "http_request_duration_seconds", "HTTP request duration in seconds, by route pattern", ["path"]
)
GITHUB_WEBHOOK_EVENTS = Counter(
    "github_webhook_events_total",
    "GitHub webhook events received by the app, by event type and processing result",
    ["event", "result"],
)
BAMBOO_REQUESTS = Counter(
    "bamboo_api_requests_total",
    "HTTP requests made to the Bamboo CI API, by operation and outcome",
    ["operation", "status"],
)
BAMBOO_DURATION = Histogram(
    "bamboo_api_request_duration_seconds", "Duration of Bamboo CI API requests in seconds, by operation", ["operation"]
)
CI_JOB_DURATION = Histogram(
    "ci_job_execution_seconds",
    "CI job execution duration in seconds, by stage name and final status",
    ["stage", "status"],
)
CI_JOB_RETRIES = Counter("ci_job_retry_total", "CI job retries triggered, by reason (partial or full)", ["reason"])
CI_TIMEOUTS = Counter(
    "ci_job_timeout_total", "Check suites marked as hanged by the timeout watchdog (no update for >2h)"
)
APP_EXCEPTIONS = Counter(
    "app_exceptions_total",
    "Unhandled exceptions caught by the web app, by exception class and handler",
    ["class", "handler"],
)
SLACK_NOTIFICATIONS = Counter(
    "slack_notifications_total",
    "Slack notifications sent by the app, by notification type and delivery status",
    ["type", "status"],
)
GITHUB_API_REQUESTS = Counter(
    "github_api_requests_total", "Requests made to the GitHub API, by method and status class", ["method", "status"]
)
AR_QUERIES = Counter(
    "activerecord_queries_total",
    "Total number of SQL queries executed, by operation type and table",
    ["operation", "table"],
)
AR_QUERY_DURATION = Histogram(
    "activerecord_query_duration_seconds",
    "Duration of SQL queries in seconds, by operation type and table",
    ["operation", "table"],
)

HTTP_SERVER_REQUESTS = Counter(
    "http_server_requests_total", "The total number of HTTP requests handled by the app.", ["code", "method", "path"]
)
HTTP_SERVER_DURATION = Histogram(
    "http_server_request_duration_seconds", "The HTTP response duration of the app.", ["method", "path"]
)
HTTP_SERVER_EXCEPTIONS = Counter(
    "http_server_exceptions_total", "The total number of exceptions raised by the app.", ["exception"]
)
# Web worker (process) saturation. uvicorn has no Puma-style thread pool; a "thread" is a request being handled in the
# worker's thread pool, "backlog" is not observable and stays 0.
PUMA_RUNNING = Gauge(
    "puma_running_threads", "Requests being handled, per web worker", ["worker"], multiprocess_mode="livesum"
)
PUMA_CAPACITY = Gauge(
    "puma_pool_capacity", "Request slots available, per web worker", ["worker"], multiprocess_mode="livesum"
)
PUMA_MAX = Gauge(
    "puma_max_threads", "Maximum concurrent requests per web worker", ["worker"], multiprocess_mode="livesum"
)
PUMA_BACKLOG = Gauge(
    "puma_backlog",
    "Requests waiting for a free slot, per web worker (not observable: always 0)",
    ["worker"],
    multiprocess_mode="livesum",
)

_inflight = 0


_DEFAULT_MAX_THREADS = 40  # anyio's default thread limiter
_started = False


def web_worker_started(max_threads: int = _DEFAULT_MAX_THREADS) -> None:
    global _started
    _started = True
    worker = str(os.getpid())
    PUMA_MAX.labels(worker=worker).set(max_threads)
    PUMA_CAPACITY.labels(worker=worker).set(max_threads)
    PUMA_RUNNING.labels(worker=worker).set(0)
    PUMA_BACKLOG.labels(worker=worker).set(0)


def web_request_in_flight(delta: int) -> None:
    global _inflight
    if not _started:
        web_worker_started()
    _inflight += delta
    worker = str(os.getpid())
    PUMA_RUNNING.labels(worker=worker).set(_inflight)
    PUMA_CAPACITY.labels(worker=worker).set(max(PUMA_MAX.labels(worker=worker)._value.get() - _inflight, 0))


def _booted_web_workers() -> int:
    directory = Path(os.environ["PROMETHEUS_MULTIPROC_DIR"])
    pids = {m.group(1) for p in directory.glob("gauge_livesum_*.db") if (m := re.search(r"_(\d+)\.db$", p.name))}
    return sum(1 for pid in pids if _alive(int(pid)))


_SQL_OPS = {"SELECT", "INSERT", "UPDATE", "DELETE"}
_TABLE_RE = re.compile(r'(?:FROM|INTO|UPDATE)\s+"?([A-Za-z_][A-Za-z0-9_]*)"?', re.I)


def track_bamboo[T](operation: str, call: Callable[[], T]) -> T | None:
    """Time a Bamboo call; exceptions are counted and swallowed (returns None)."""
    start = time.monotonic()
    try:
        result = call()
    except Exception:
        BAMBOO_REQUESTS.labels(operation=operation, status="error").inc()
        BAMBOO_DURATION.labels(operation=operation).observe(time.monotonic() - start)
        return None
    status = "error"
    if result is not None:
        code = getattr(result, "status_code", None)
        status = "success" if code is None or int(code) < 400 else "error"
    BAMBOO_REQUESTS.labels(operation=operation, status=status).inc()
    BAMBOO_DURATION.labels(operation=operation).observe(time.monotonic() - start)
    return result


def track_slack[T](kind: str, call: Callable[[], T]) -> T | None:
    try:
        result = call()
    except Exception:
        SLACK_NOTIFICATIONS.labels(type=kind, status="error").inc()
        return None
    SLACK_NOTIFICATIONS.labels(type=kind, status="error" if result is None else "sent").inc()
    return result


def instrument_engine(engine: Any) -> None:
    from sqlalchemy import event

    if getattr(engine, "_netdef_instrumented", False):
        return
    engine._netdef_instrumented = True

    @event.listens_for(engine, "before_cursor_execute")
    def _before(conn: Any, cursor: Any, statement: str, parameters: Any, context: Any, executemany: bool) -> None:
        conn.info["query_start"] = time.monotonic()

    @event.listens_for(engine, "after_cursor_execute")
    def _after(conn: Any, cursor: Any, statement: str, parameters: Any, context: Any, executemany: bool) -> None:
        operation = statement.lstrip().split(None, 1)[0].upper() if statement.strip() else ""
        if operation not in _SQL_OPS:
            return
        match = _TABLE_RE.search(statement)
        table = match.group(1) if match else "unknown"
        AR_QUERIES.labels(operation=operation, table=table).inc()
        AR_QUERY_DURATION.labels(operation=operation, table=table).observe(
            time.monotonic() - conn.info.pop("query_start", time.monotonic())
        )


def cleanup_stale_metric_files() -> None:
    """Remove files of dead processes."""
    directory = Path(os.environ["PROMETHEUS_MULTIPROC_DIR"])
    for path in directory.glob("*_*.db"):
        match = re.search(r"_(\d+)\.db$", path.name)
        if not match:
            continue
        pid = int(match.group(1))
        if pid != os.getpid() and not _alive(pid):
            path.unlink(missing_ok=True)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class DatabaseCollector:
    """Gauges computed from PostgreSQL at scrape time (job queue, CI domain, connection pool)."""

    def __init__(self, session_factory: Callable[[], Any], engine: Any) -> None:
        self._session_factory = session_factory
        self._engine = engine

    def collect(self) -> Iterable[GaugeMetricFamily]:
        from sqlalchemy import func, select

        from netdef_ci.db import utcnow
        from netdef_ci.enums import Status
        from netdef_ci.models import CiJob, Job, Stage

        settings = get_settings()
        now = utcnow()
        families: dict[str, GaugeMetricFamily] = {}

        def gauge(name: str, doc: str, labels: list[str]) -> GaugeMetricFamily:
            families[name] = GaugeMetricFamily(name, doc, labels=labels)
            return families[name]

        pending = gauge(
            "delayed_jobs_pending", "Jobs waiting to run (run_at <= now, not locked, not failed)", ["queue"]
        )
        running = gauge("delayed_jobs_running", "Jobs currently locked by a worker", ["queue"])
        scheduled = gauge("delayed_jobs_scheduled", "Jobs scheduled to run in the future (run_at > now)", ["queue"])
        failed = gauge("delayed_jobs_failed", "Jobs that have permanently failed (failed_at IS NOT NULL)", ["queue"])
        maxed = gauge("delayed_jobs_max_attempts_reached", "Jobs that have exhausted all retry attempts", ["queue"])
        stuck = gauge(
            "delayed_jobs_locked_too_long", "Jobs locked longer than max_run_time, indicating a stuck worker", ["queue"]
        )
        table = gauge(
            "delayed_jobs_table",
            "Unix timestamp of each scheduled job",
            ["job_id", "queue", "job_class", "job_args", "run_at"],
        )
        workers_total = gauge("puma_workers_total", "Number of web worker processes configured", [])
        workers_total.add_metric([], settings.web_workers)
        workers_booted = gauge("puma_booted_workers", "Number of web worker processes currently running", [])
        workers_booted.add_metric([], _booted_web_workers())
        ci_jobs = gauge("ci_jobs_total", "CI jobs grouped by status", ["status"])
        ci_stages = gauge("ci_stages_total", "CI stages grouped by status", ["status"])

        with self._session_factory() as session:

            def per_queue(*conditions: Any) -> dict[str, int]:
                stmt = select(Job.queue, func.count()).where(*conditions).group_by(Job.queue)
                return {str(q): int(c) for q, c in session.execute(stmt)}

            lock_limit = now - timedelta(seconds=settings.job_max_run_time_seconds)
            counts = [
                (pending, per_queue(Job.run_at <= now, Job.locked_at.is_(None), Job.failed_at.is_(None))),
                (running, per_queue(Job.locked_at.is_not(None), Job.failed_at.is_(None))),
                (scheduled, per_queue(Job.run_at > now, Job.locked_at.is_(None), Job.failed_at.is_(None))),
                (failed, per_queue(Job.failed_at.is_not(None))),
                (maxed, per_queue(Job.attempts >= Job.max_attempts, Job.failed_at.is_(None))),
                (stuck, per_queue(Job.locked_at.is_not(None), Job.locked_at < lock_limit, Job.failed_at.is_(None))),
            ]
            queues = {q for _family, values in counts for q in values}
            for family, values in counts:
                for queue in sorted(queues):
                    family.add_metric([queue], values.get(queue, 0))
            for job in session.scalars(
                select(Job).where(Job.run_at > now, Job.locked_at.is_(None), Job.failed_at.is_(None))
            ):
                args = ", ".join(str(a) for a in job.args)
                args = args if len(args) <= 80 else f"{args[:77]}..."
                table.add_metric(
                    [str(job.id), str(job.queue or ""), job.handler, args, job.run_at.isoformat()],
                    job.run_at.timestamp(),
                )
            since = now - timedelta(hours=settings.ci_metrics_window_hours)
            for model, family in ((CiJob, ci_jobs), (Stage, ci_stages)):
                rows = dict(
                    session.execute(
                        select(model.status, func.count()).where(model.updated_at >= since).group_by(model.status)
                    ).all()
                )
                for status in ("queued", "in_progress", "success", "cancelled", "failure", "skipped"):
                    family.add_metric([status], rows.get(Status[status.upper()], 0))

        pool = getattr(self._engine, "pool", None)
        if pool is not None and hasattr(pool, "checkedout"):
            size = getattr(pool, "size", lambda: 0)()
            busy = pool.checkedout()
            checkedin = pool.checkedin()
            for name, doc, value in (
                ("activerecord_connection_pool_size", "Maximum number of connections allowed in the pool", size),
                (
                    "activerecord_connection_pool_connections",
                    "Current number of connections in the pool",
                    busy + checkedin,
                ),
                ("activerecord_connection_pool_busy", "Connections currently checked out by a thread", busy),
                ("activerecord_connection_pool_idle", "Connections available for checkout", checkedin),
                # SQLAlchemy's pool does not expose its waiters; reported as 0.
                (
                    "activerecord_connection_pool_waiting",
                    "Threads waiting to obtain a connection (not observable: 0)",
                    0,
                ),
            ):
                family = GaugeMetricFamily(name, doc)
                family.add_metric([], value)
                families[name] = family
        yield from families.values()


def render(session_factory: Callable[[], Any] | None = None, engine: Any = None) -> bytes:
    registry = CollectorRegistry()
    MultiProcessCollector(registry)
    if session_factory is not None:
        registry.register(DatabaseCollector(session_factory, engine))  # type: ignore[arg-type]
    return generate_latest(registry)
