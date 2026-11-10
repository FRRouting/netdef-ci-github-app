#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/pull_request_subscription.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack notification subscription (port of lib/models/pull_request_subscription.rb)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.models.base import Base, BigId, _ts, _ts_updated


class PullRequestSubscription(Base):
    __tablename__ = "pull_request_subscriptions"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    slack_user_id: Mapped[str] = mapped_column(String, nullable=False)
    rule: Mapped[str] = mapped_column(String, nullable=False)
    target: Mapped[str] = mapped_column(String, nullable=False, index=True)
    notification: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)
