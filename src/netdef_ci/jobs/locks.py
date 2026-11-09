#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/locks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Per pull-request serialization (PostgreSQL advisory locks) for flows that cancel/start executions and for the
admission of the commands that do so."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import text
from sqlalchemy.orm import Session

from netdef_ci.db import get_engine

_NAMESPACE = 0x4E44_0000_0000  # "ND" namespace so that ids cannot collide with other advisory-lock users


@contextmanager
def pull_request_lock(pull_request_id: int) -> Iterator[None]:
    engine = get_engine()
    if engine.dialect.name != "postgresql":
        yield
        return
    key = _NAMESPACE | int(pull_request_id)
    # A dedicated connection: session-level advisory locks belong to the connection, not to the ORM session.
    with engine.connect() as conn:
        conn.execute(text("SELECT pg_advisory_lock(:key)"), {"key": key})
        try:
            yield
        finally:
            conn.execute(text("SELECT pg_advisory_unlock(:key)"), {"key": key})
            conn.commit()


_ADMISSION_NAMESPACE = 0x4E43_0000_0000  # "NC": distinct from the execution lock of the same pull request


def admission_lock(session: Session, pull_request_id: int) -> None:
    """Serialize the admission of `ci:retry`/`ci:rerun` requests of one pull request: a transaction-scoped lock on the
    session's own connection, released by its next commit or rollback (held for milliseconds, never across a job)."""
    if session.get_bind().dialect.name != "postgresql":
        return
    session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": _ADMISSION_NAMESPACE | int(pull_request_id)})
