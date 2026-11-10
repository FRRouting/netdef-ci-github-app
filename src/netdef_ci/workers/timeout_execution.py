#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/timeout_execution.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Finishes an execution that stopped receiving updates (port of workers/timeout_execution.rb)."""

from __future__ import annotations

from datetime import timedelta

from sqlalchemy.orm import Session

from netdef_ci.github.plan_execution.finished import Finished
from netdef_ci.helpers import metrics
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.db import session_scope, utcnow
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CheckSuite


def timeout_execution(session: Session, check_suite_id: int) -> bool:
    log = Log("timeout_execution_worker")
    check_suite = session.get(CheckSuite, check_suite_id)
    if check_suite is None:
        raise LookupError(f"CheckSuite {check_suite_id} not found")
    settings = get_settings()
    finished = check_suite.is_finished()
    log.info("Timeout execution for check_suite_id: %s -> finished? %s", check_suite_id, finished)
    if finished:
        return False
    last_update = check_suite.last_job_updated_at() or check_suite.updated_at
    if last_update < utcnow() - timedelta(hours=settings.timeout_hang_hours):
        metrics.CI_TIMEOUTS.inc()
        Finished(session, {"check_suite_id": check_suite.id, "hanged": True}).finished()
        return True
    log.info("Rescheduling check_suite_id: %s", check_suite_id)
    jobs_queue.enqueue(
        session,
        "timeout_execution",
        [check_suite_id],
        queue="timeout_execution",
        delay_seconds=settings.timeout_check_minutes * 60,
        dedupe_key=f"suite-{check_suite_id}",  # same key as action.timeout_dedupe_key
    )
    return False


@job_handler("timeout_execution")
def timeout_execution_job(check_suite_id: int) -> None:
    with session_scope() as session:
        timeout_execution(session, check_suite_id)
