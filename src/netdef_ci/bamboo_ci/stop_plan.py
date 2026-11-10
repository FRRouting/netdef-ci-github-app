#  SPDX-License-Identifier: BSD-2-Clause
#
#  bamboo_ci/stop_plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Stopping a previous execution in Bamboo before a new one starts: wait for the stop, and the database
side of the stopped suite (port of BambooCi::StopPlan, plus the checks the Python port adds)."""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from sqlalchemy import exists, or_, select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.enums import Status
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.logs import Log
from netdef_ci.models import CheckSuite, CiJob, Stage


def last_in_progress_stage(session: Session, check_suite: CheckSuite) -> Stage | None:
    return session.scalars(
        select(Stage)
        .where(Stage.check_suite_id == check_suite.id, Stage.status == Status.IN_PROGRESS)
        .order_by(Stage.id.desc())
        .limit(1)
    ).first()


def started_without_checks(session: Session, check_suite: CheckSuite) -> bool:
    """Started in Bamboo, but its GitHub setup died before creating any stage or CI job (PR 8118). Its stages cannot
    tell whether it still runs, so Bamboo is asked."""
    if not check_suite.bamboo_ci_ref:
        return False
    has_rows = session.scalar(
        select(
            or_(
                exists().where(Stage.check_suite_id == check_suite.id),
                exists().where(CiJob.check_suite_id == check_suite.id),
            )
        )
    )
    return not has_rows and not container.bamboo().is_stopped(check_suite.bamboo_ci_ref)


def cancel_jobs_without_check_run(jobs: list[CiJob], github: Any) -> None:
    """Database-only cancellation before the Bamboo stop: late callbacks of the stopped build then find the jobs
    closed. Jobs with a check run (never created by this app) are cancelled on GitHub by ChecksSetup."""
    for ci_job in jobs:
        if ci_job.check_ref is None:
            ci_job.cancelled(github, commit=False)


def wait_until_stopped(
    bamboo_ci_refs: list[str | None], log: Log, *, sleep: Callable[[float], None] = time.sleep
) -> bool:
    """After a stop request, wait (bounded by EXECUTION_CANCEL_WAIT_MAX_SECONDS) until Bamboo reports every given
    execution as stopped. Returns False when the limit was reached; the caller starts the new execution anyway."""
    settings = get_settings()
    pending = [ref for ref in bamboo_ci_refs if ref]
    deadline = time.monotonic() + settings.execution_cancel_wait_max_seconds
    while True:
        pending = [ref for ref in pending if not container.bamboo().is_stopped(ref)]
        if not pending:
            return True
        if time.monotonic() >= deadline:
            log.error(
                "Bamboo did not confirm the stop of %s within %ss; starting the new execution anyway",
                ", ".join(pending),
                settings.execution_cancel_wait_max_seconds,
            )
            return False
        sleep(settings.execution_cancel_poll_seconds)
