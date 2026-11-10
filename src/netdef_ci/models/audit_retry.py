#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/audit_retry.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Audit trail of retries and re-runs (port of lib/models/audit_retry.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated, audit_retries_ci_jobs

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.check_suite import CheckSuite
    from netdef_ci.models.ci_job import CiJob


class AuditRetry(Base):
    __tablename__ = "audit_retries"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    github_username: Mapped[str | None] = mapped_column(String)
    github_id: Mapped[str | None] = mapped_column(String)
    github_type: Mapped[str | None] = mapped_column(String)
    retry_type: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    check_suite_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("check_suites.id"), index=True)
    github_user_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("github_users.id"), index=True)

    check_suite: Mapped[CheckSuite | None] = relationship(back_populates="audit_retries")
    ci_jobs: Mapped[list[CiJob]] = relationship(secondary=audit_retries_ci_jobs, back_populates="audit_retries")
