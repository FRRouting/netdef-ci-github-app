#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/job.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Background job row of the queue in `jobs/queue.py` (replaces Delayed Job's `delayed_jobs` table)."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import JSON, DateTime, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.helpers.db import utcnow
from netdef_ci.models.base import Base, BigId, _ts, _ts_updated


class Job(Base):
    """Background job (PostgreSQL-backed queue)."""

    __tablename__ = "jobs"
    __table_args__ = (
        Index("index_jobs_on_queue_and_run_at", "queue", "run_at"),
        Index("index_jobs_on_handler_and_dedupe_key", "handler", "dedupe_key"),
    )

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    queue: Mapped[str | None] = mapped_column(String)
    handler: Mapped[str] = mapped_column(String, nullable=False)
    args: Mapped[list[Any]] = mapped_column(JSON, nullable=False, default=list)
    priority: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=5)
    run_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow)
    locked_at: Mapped[datetime | None] = mapped_column(DateTime)
    locked_by: Mapped[str | None] = mapped_column(String)
    failed_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_error: Mapped[str | None] = mapped_column(Text)
    dedupe_key: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
