#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Bamboo plan run for a repository or pull request (port of lib/models/plan.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.pull_request import PullRequest


class Plan(Base):
    __tablename__ = "plans"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    bamboo_ci_plan_name: Mapped[str] = mapped_column(String, nullable=False)
    github_repo_name: Mapped[str] = mapped_column(String, nullable=False, default="0", index=True)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    check_suite_id: Mapped[int | None] = mapped_column(BigId, index=True)  # unused column
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)
    name: Mapped[str] = mapped_column(String, nullable=False, default="")

    pull_request: Mapped[PullRequest | None] = relationship(back_populates="plans", foreign_keys=[pull_request_id])
