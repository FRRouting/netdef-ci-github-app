#  SPDX-License-Identifier: BSD-2-Clause
#
#  db.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Database engine/session handling. Timestamps are naive UTC, like Rails' default for the shared schema."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from netdef_ci.config import get_settings

_engine: Engine | None = None
_factory: sessionmaker[Session] | None = None


def utcnow() -> datetime:
    """Naive UTC "now" (the Ruby app stores UTC in `timestamp without time zone`)."""
    return datetime.now(UTC).replace(tzinfo=None)


def build_engine(url: str | None = None, **kwargs: Any) -> Engine:
    settings = get_settings()
    url = url or settings.database_url
    options: dict[str, Any] = {"pool_pre_ping": True, "future": True}
    if not url.startswith("sqlite"):
        options.update(pool_size=settings.db_pool_size, max_overflow=5)
    options.update(kwargs)
    return create_engine(url, **options)


def init_engine(url: str | None = None, **kwargs: Any) -> Engine:
    global _engine, _factory
    _engine = build_engine(url, **kwargs)
    _factory = sessionmaker(bind=_engine, expire_on_commit=False, future=True)
    from netdef_ci import metrics

    metrics.instrument_engine(_engine)
    return _engine


def get_engine() -> Engine:
    if _engine is None:
        init_engine()
    assert _engine is not None
    return _engine


def session_factory() -> sessionmaker[Session]:
    if _factory is None:
        init_engine()
    assert _factory is not None
    return _factory


def new_session() -> Session:
    return session_factory()()


@contextmanager
def session_scope() -> Iterator[Session]:
    """Session that is always closed; callers commit explicitly (the Ruby code autocommits per save)."""
    session = new_session()
    try:
        yield session
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def dispose_engine() -> None:
    global _engine, _factory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _factory = None


__all__ = ["event", "utcnow", "init_engine", "get_engine", "session_factory", "new_session", "session_scope"]
