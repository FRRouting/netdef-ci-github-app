#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/check_suite.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""One execution of a plan for a commit (port of lib/models/check_suite.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Boolean, ForeignKey, Index, Integer, String, exists, func, select
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.enums import RUNNING_STATUSES, Status
from netdef_ci.models.base import Base, BigId, _session, _ts, _ts_updated
from netdef_ci.models.ci_job import CiJob
from netdef_ci.models.stage import Stage

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.audit_retry import AuditRetry
    from netdef_ci.models.plan import Plan
    from netdef_ci.models.pull_request import PullRequest


class CheckSuite(Base):
    __tablename__ = "check_suites"
    __table_args__ = (
        # text_pattern_ops serves both `=` and the prefix match of `ci:rerun #<short sha>`.
        Index(
            "index_check_suites_on_commit_sha_ref",
            "commit_sha_ref",
            postgresql_ops={"commit_sha_ref": "text_pattern_ops"},
        ),
    )

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    author: Mapped[str] = mapped_column(String, nullable=False)
    commit_sha_ref: Mapped[str] = mapped_column(String, nullable=False)
    base_sha_ref: Mapped[str] = mapped_column(String, nullable=False)
    bamboo_ci_ref: Mapped[str | None] = mapped_column(String, index=True)
    merge_branch: Mapped[str | None] = mapped_column(String)
    work_branch: Mapped[str | None] = mapped_column(String)
    details: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)
    re_run: Mapped[bool | None] = mapped_column(Boolean, default=False)
    retry: Mapped[int | None] = mapped_column(Integer, default=0)
    sync: Mapped[bool | None] = mapped_column(Boolean, default=False)
    github_user_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("github_users.id"), index=True)
    # The DB has an FK to stages.id; it is not declared here to keep metadata free of an FK cycle.
    stopped_in_stage_id: Mapped[int | None] = mapped_column(BigId, index=True)
    cancelled_previous_check_suite_id: Mapped[int | None] = mapped_column(
        BigId, ForeignKey("check_suites.id"), index=True
    )
    plan_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("plans.id"), index=True)

    pull_request: Mapped[PullRequest | None] = relationship(
        back_populates="check_suites", foreign_keys=[pull_request_id]
    )
    plan: Mapped[Plan | None] = relationship(foreign_keys=[plan_id])
    stages: Mapped[list[Stage]] = relationship(
        back_populates="check_suite", order_by="Stage.id", foreign_keys="Stage.check_suite_id"
    )
    ci_jobs: Mapped[list[CiJob]] = relationship(
        back_populates="check_suite", order_by="CiJob.id", foreign_keys="CiJob.check_suite_id"
    )
    audit_retries: Mapped[list[AuditRetry]] = relationship(back_populates="check_suite")

    def is_running(self) -> bool:
        return bool(
            _session(self).scalar(
                select(exists().where(Stage.check_suite_id == self.id, Stage.status.in_(list(RUNNING_STATUSES))))
            )
        )

    def is_finished(self) -> bool:
        return not self.is_running()

    def is_in_progress(self) -> bool:
        return not self.is_finished()

    def running_jobs(self) -> list[CiJob]:
        return list(
            _session(self).scalars(
                select(CiJob)
                .where(CiJob.check_suite_id == self.id, CiJob.status.in_(list(RUNNING_STATUSES)))
                .order_by(CiJob.id)
            )
        )

    def stages_failure(self) -> list[Stage]:
        stmt = (
            select(Stage)
            .join(CiJob, CiJob.stage_id == Stage.id)
            .where(Stage.check_suite_id == self.id, CiJob.status.in_([Status.CANCELLED, Status.FAILURE]))
            .order_by(Stage.id)
        )
        seen: dict[int, Stage] = {}
        for stage in _session(self).scalars(stmt):
            seen.setdefault(stage.id, stage)
        return list(seen.values())

    def last_job_updated_at(self) -> datetime | None:
        return _session(self).scalar(select(func.max(CiJob.updated_at)).where(CiJob.check_suite_id == self.id))
