#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/ci_job.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Bamboo job of an execution (port of lib/models/ci_job.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.enums import RUNNING_STATUSES, Status
from netdef_ci.models.audit_status import AuditStatus, audit_pair
from netdef_ci.models.base import Base, BigId, Output, StatusType, _session, _ts, _ts_updated, audit_retries_ci_jobs

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.clients.github import GithubCheck
    from netdef_ci.models.audit_retry import AuditRetry
    from netdef_ci.models.check_suite import CheckSuite
    from netdef_ci.models.stage import Stage
    from netdef_ci.models.topotest_failure import TopotestFailure


class CiJob(Base):
    __tablename__ = "ci_jobs"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    job_ref: Mapped[str | None] = mapped_column(String, index=True)
    check_ref: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated(index=True)
    check_suite_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("check_suites.id"), index=True)
    retry: Mapped[int | None] = mapped_column(Integer, default=0)
    parent_stage_id: Mapped[int | None] = mapped_column(Integer)
    stage_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("stages.id"), index=True)
    execution_time: Mapped[int | None] = mapped_column(Integer)
    summary: Mapped[str | None] = mapped_column(String)
    # Tail of the failed build log, fetched from Bamboo once and reused by every summary rebuild.
    build_log: Mapped[str | None] = mapped_column(Text)

    check_suite: Mapped[CheckSuite | None] = relationship(back_populates="ci_jobs", foreign_keys=[check_suite_id])
    stage: Mapped[Stage | None] = relationship(back_populates="jobs", foreign_keys=[stage_id])
    topotest_failures: Mapped[list[TopotestFailure]] = relationship(order_by="TopotestFailure.id")
    audit_retries: Mapped[list[AuditRetry]] = relationship(secondary=audit_retries_ci_jobs, back_populates="ci_jobs")

    @property
    def state(self) -> Status:
        return Status(self.status)

    def is_finished(self) -> bool:
        return self.state not in RUNNING_STATUSES

    def update_execution_time(self, *, commit: bool = True) -> None:
        started, finished = audit_pair(self, "CiJob")
        if started is None or finished is None:
            return
        duration = (finished.created_at - started.created_at).total_seconds()
        self.execution_time = int(duration)
        if commit:
            _session(self).commit()
        from netdef_ci.helpers import metrics

        stage_name = self.stage.configuration.bamboo_stage_name if self.stage and self.stage.configuration else None
        metrics.CI_JOB_DURATION.labels(stage=stage_name or "unknown", status=self.state.label).observe(duration)

    # Transitions commit by default; `commit=False` lets a loop over many jobs commit once at the end.
    def create_check_run(self, agent: str = "Github", *, commit: bool = True) -> None:
        self._record(Status.QUEUED, agent, commit)

    def enqueue(
        self,
        _github: GithubCheck | None = None,
        _output: Output | None = None,
        agent: str = "Github",
        *,
        commit: bool = True,
    ) -> None:
        self._record(Status.QUEUED, agent, commit)

    def in_progress(
        self, github: GithubCheck, output: Output | None = None, agent: str = "Github", *, commit: bool = True
    ) -> None:
        self._transition(github, Status.IN_PROGRESS, github.in_progress, output, agent, commit)

    def cancelled(
        self, github: GithubCheck, output: Output | None = None, agent: str = "Github", *, commit: bool = True
    ) -> None:
        self._transition(github, Status.CANCELLED, github.cancelled, output, agent, commit)

    def failure(
        self, github: GithubCheck, output: Output | None = None, agent: str = "Github", *, commit: bool = True
    ) -> None:
        self._transition(github, Status.FAILURE, github.failure, output, agent, commit)

    def success(
        self, github: GithubCheck, output: Output | None = None, agent: str = "Github", *, commit: bool = True
    ) -> None:
        self._transition(github, Status.SUCCESS, github.success, output, agent, commit)

    def skipped(
        self, github: GithubCheck, output: Output | None = None, agent: str = "Github", *, commit: bool = True
    ) -> None:
        self._transition(github, Status.SKIPPED, github.skipped, output, agent, commit)

    def _transition(
        self, github: GithubCheck, status: Status, call: Any, output: Output | None, agent: str, commit: bool = True
    ) -> None:
        # Jobs only own a GitHub check run when `check_ref` is set (the app never creates one for jobs).
        if self.check_ref is not None:
            call(self.check_ref, output or {})
        self._record(status, agent, commit)

    def _record(self, status: Status, agent: str, commit: bool = True) -> None:
        session = _session(self)
        session.add(AuditStatus(auditable_type="CiJob", auditable_id=self.id, status=status, agent=agent))
        self.status = status
        if status in RUNNING_STATUSES:
            self.build_log = None  # a new run produces a new log
        if commit:
            session.commit()
