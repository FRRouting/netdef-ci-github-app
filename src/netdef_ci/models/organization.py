#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/organization.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Organization of GitHub users (port of lib/models/organization.rb)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated


class Organization(Base):
    __tablename__ = "organizations"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    contact_email: Mapped[str | None] = mapped_column(String)
    contact_name: Mapped[str | None] = mapped_column(String)
    url: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()

    def __repr__(self) -> str:
        return (
            f"Organization id: {self.id}, name: {self.name}, contact_email: {self.contact_email}, "
            f"contact_name: {self.contact_name}, url: {self.url} "
            f"created_at: {self.created_at}, updated_at: {self.updated_at}"
        )
