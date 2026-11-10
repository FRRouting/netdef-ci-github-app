#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/watch_dog.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Periodic check of executions that look stuck (port of workers/watch_dog.rb)."""

from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.enums import Status
from netdef_ci.github.plan_execution.finished import Finished
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.db import utcnow
from netdef_ci.helpers.logs import Log
from netdef_ci.models import CheckSuite, Stage


def watch_dog(session: Session) -> int:
    log = Log("watch_dog")
    log.info(">>> Running watchdog")
    # Suites older than the window are left alone: one Bamboo never closes would otherwise be queried forever.
    since = utcnow() - timedelta(hours=get_settings().watch_dog_max_age_hours)
    ids = list(
        session.scalars(
            select(CheckSuite.id)
            .join(Stage, Stage.check_suite_id == CheckSuite.id)
            .where(Stage.status.in_([Status.QUEUED, Status.IN_PROGRESS]), CheckSuite.created_at >= since)
            .distinct()
            .order_by(CheckSuite.id)
        )
    )
    log.info(">>> Suites that need to be updated: %s", len(ids))
    for suite in session.scalars(select(CheckSuite).where(CheckSuite.id.in_(ids)).order_by(CheckSuite.id)):
        log.info(">>> Updating suite: %s", suite.id)
        try:
            Finished(session, {"bamboo_ref": suite.bamboo_ci_ref, "check_suite_id": suite.id}).finished()
        except Exception as error:
            session.rollback()
            log.error("WatchDog failed for suite %s: %s: %s", suite.id, type(error).__name__, error)
    log.info(">>> Stopping watchdog")
    return len(ids)
