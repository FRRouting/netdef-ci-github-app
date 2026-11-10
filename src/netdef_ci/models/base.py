#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/base.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Declarative base, column types and helpers shared by the models."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, Column, DateTime, ForeignKey, Integer, MetaData, Table, TypeDecorator
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, object_session

from netdef_ci.enums import Status
from netdef_ci.helpers.db import utcnow

Output = dict[str, str]


BigId = BigInteger().with_variant(Integer, "sqlite")


class Base(DeclarativeBase):
    # Index names ("index_<table>_on_<column>") so the ORM metadata matches the baseline migration.
    metadata = MetaData(naming_convention={"ix": "index_%(table_name)s_on_%(column_0_name)s"})


class StatusType(TypeDecorator[Status]):
    """Integer column exposed as `Status` (stable integer values)."""

    impl = Integer
    cache_ok = True

    def process_bind_param(self, value: Any, dialect: Any) -> int | None:
        return None if value is None else int(value)

    def process_result_value(self, value: Any, dialect: Any) -> Status | None:
        return None if value is None else Status(value)


def _session(obj: Any) -> Session:
    session = object_session(obj)
    if session is None:  # pragma: no cover - programming error
        raise RuntimeError(f"{type(obj).__name__} is not attached to a session")
    return session


def _ts() -> Mapped[datetime]:
    return mapped_column(DateTime, nullable=False, default=utcnow)


def _ts_updated(*, index: bool = False) -> Mapped[datetime]:
    return mapped_column(DateTime, nullable=False, default=utcnow, onupdate=utcnow, index=index)


audit_retries_ci_jobs = Table(
    "audit_retries_ci_jobs",
    Base.metadata,
    Column("ci_job_id", BigId, ForeignKey("ci_jobs.id"), index=True),
    Column("audit_retry_id", BigId, ForeignKey("audit_retries.id"), index=True),
)
