#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/duplicate_request_guard.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Burst protection of the commands that stop and restart the Bamboo executions of a pull request (`ci:retry` and
`ci:rerun`, as comments or from the Checks UI): one command at a time per pull request, and none again right after one
started. The first request wins; the others are refused with 409 instead of stopping what the first one started.

Counterpart of Github::DuplicateRequestGuard, which drops duplicates within 60 s with 202; this version also
refuses a command while another one of the same pull request is pending (see doc/07-design-notes.md)."""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from datetime import timedelta
from typing import Any

from sqlalchemy import exists, select
from sqlalchemy.orm import Session

from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.db import utcnow
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.locks import admission_lock
from netdef_ci.models import AuditRetry, CheckSuite, Job

Response = tuple[int, str]

COMMAND_JOBS = ("retry_execution", "create_execution_by_comment", "create_execution_by_command")


class CommandGuard:
    def __init__(self, session: Session, pull_request_id: int) -> None:
        self.session = session
        self.pull_request_id = pull_request_id
        self.log = Log("command_guard")

    @property
    def dedupe_key(self) -> str:
        """Marks the jobs of an admitted command, so the next request can see that one is still pending or running."""
        return f"ci-command:{self.pull_request_id}"

    @contextmanager
    def admission(self) -> Iterator[Response | None]:
        """Yield the refusal of a new command, or None when it is admitted; the caller then schedules its jobs with
        `enqueue`. Concurrent requests of the same pull request wait for each other here (PostgreSQL), and the jobs
        commit on exit, so the next request sees them."""
        admission_lock(self.session, self.pull_request_id)
        try:
            refusal = self._refusal()
            if refusal is not None:
                self.log.warning("Command refused for pull request %s: %s", self.pull_request_id, refusal[1])
            yield refusal
            self.session.commit()
        except Exception:
            self.session.rollback()
            raise

    def enqueue(self, handler: str, args: Sequence[Any], *, queue: str, delay_seconds: float = 0) -> Job:
        """Schedule a job of the admitted command (committed when `admission` exits)."""
        return jobs_queue.enqueue(
            self.session,
            handler,
            args,
            queue=queue,
            delay_seconds=delay_seconds,
            max_attempts=1,  # stops and starts Bamboo executions: never repeated automatically
            dedupe_key=self.dedupe_key,
            commit=False,
        )

    def _refusal(self) -> Response | None:
        if self._in_flight():
            return 409, "Another ci:retry/ci:rerun is in progress for this pull request"
        if self._recently_started():
            return 409, "A ci:retry/ci:rerun started moments ago for this pull request"
        return None

    def _in_flight(self) -> bool:
        """Jobs are deleted when they finish, so any row left with this key is pending or running."""
        return bool(
            self.session.scalar(
                select(
                    exists().where(
                        Job.handler.in_(COMMAND_JOBS), Job.dedupe_key == self.dedupe_key, Job.failed_at.is_(None)
                    )
                )
            )
        )

    def _recently_started(self) -> bool:
        """An `AuditRetry` (written when a retry or rerun starts) younger than CI_COMMAND_COOLDOWN_SECONDS."""
        cooldown = get_settings().ci_command_cooldown_seconds
        if cooldown <= 0:
            return False
        since = utcnow() - timedelta(seconds=cooldown)
        return bool(
            self.session.scalar(
                select(
                    exists()
                    .where(AuditRetry.check_suite_id == CheckSuite.id)
                    .where(CheckSuite.pull_request_id == self.pull_request_id, AuditRetry.created_at >= since)
                )
            )
        )
