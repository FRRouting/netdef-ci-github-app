#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/github_user.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""GitHub user who opened or retried an execution (port of lib/models/github_user.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.organization import Organization


class GithubUser(Base):
    __tablename__ = "github_users"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    github_login: Mapped[str | None] = mapped_column(String, index=True)
    github_username: Mapped[str | None] = mapped_column(String)
    github_email: Mapped[str | None] = mapped_column(String)
    github_id: Mapped[int | None] = mapped_column(Integer, unique=True, index=True)
    github_organization: Mapped[str | None] = mapped_column(String)
    github_type: Mapped[str | None] = mapped_column(String)
    organization_name: Mapped[str | None] = mapped_column(String)
    organization_url: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    organization_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("organizations.id"), index=True)
    slack_username: Mapped[str | None] = mapped_column(String)
    slack_id: Mapped[str | None] = mapped_column(String)

    organization: Mapped[Organization | None] = relationship()
