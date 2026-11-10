#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/topotest_failure.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Topotest failure of a CI job (port of lib/models/topotest_failure.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated


class TopotestFailure(Base):
    __tablename__ = "topotest_failures"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    test_suite: Mapped[str] = mapped_column(String, nullable=False)
    test_case: Mapped[str] = mapped_column(String, nullable=False)
    message: Mapped[str] = mapped_column(String, nullable=False)
    execution_time: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    ci_job_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("ci_jobs.id"), index=True)

    def to_dict(self) -> dict[str, Any]:
        return {
            "suite": self.test_suite,
            "case": self.test_case,
            "message": self.message,
            "execution_time": self.execution_time,
        }
