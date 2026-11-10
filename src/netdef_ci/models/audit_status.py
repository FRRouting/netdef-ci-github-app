#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/audit_status.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Audit trail of status transitions of stages and CI jobs (port of lib/models/audit_status.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import Index, String, select
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.enums import Status
from netdef_ci.models.base import Base, BigId, StatusType, _session, _ts

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.ci_job import CiJob
    from netdef_ci.models.stage import Stage


def audit_pair(obj: CiJob | Stage, kind: str) -> tuple[AuditStatus | None, AuditStatus | None]:
    session = _session(obj)
    base = select(AuditStatus).where(AuditStatus.auditable_type == kind, AuditStatus.auditable_id == obj.id)
    started = session.scalars(
        base.where(AuditStatus.status == Status.IN_PROGRESS).order_by(AuditStatus.id).limit(1)
    ).first()
    finished = session.scalars(
        base.where(AuditStatus.status.in_([Status.SUCCESS, Status.FAILURE])).order_by(AuditStatus.id).limit(1)
    ).first()
    return started, finished


class AuditStatus(Base):
    __tablename__ = "audit_statuses"
    __table_args__ = (
        Index("index_audit_statuses_on_auditable_type_and_auditable_id", "auditable_type", "auditable_id"),
    )

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    agent: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    auditable_type: Mapped[str] = mapped_column(String, nullable=False)
    auditable_id: Mapped[int] = mapped_column(BigId, nullable=False)
