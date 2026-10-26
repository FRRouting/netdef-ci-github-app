#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/locks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Per pull-request serialization (PostgreSQL advisory locks) for flows that cancel/start executions."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import text

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
