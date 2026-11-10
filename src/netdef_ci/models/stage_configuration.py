#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/stage_configuration.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Configuration of a Bamboo stage: GitHub check run name, retry and start rules (port of lib/models/stage_configuration.rb)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated


class StageConfiguration(Base):
    __tablename__ = "stage_configurations"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    bamboo_stage_name: Mapped[str] = mapped_column(String, nullable=False)
    github_check_run_name: Mapped[str] = mapped_column(String, nullable=False)
    start_in_progress: Mapped[bool | None] = mapped_column(Boolean, default=False)
    can_retry: Mapped[bool | None] = mapped_column(Boolean, default=True)
    position: Mapped[int | None] = mapped_column(Integer)
    mandatory: Mapped[bool | None] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
