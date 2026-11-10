#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/webhook_delivery.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Processed GitHub deliveries and Bamboo callbacks, used to drop redeliveries (no Ruby equivalent)."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from netdef_ci.helpers.db import utcnow
from netdef_ci.models.base import Base, BigId


class WebhookDelivery(Base):
    __tablename__ = "webhook_deliveries"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    delivery_id: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    event: Mapped[str | None] = mapped_column(String)
    received_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow, index=True)
