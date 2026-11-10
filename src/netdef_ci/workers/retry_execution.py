#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/retry_execution.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`retry_execution` job: runs a scheduled retry serialized with the executions of the same pull request. The Ruby
application runs Github::Retry inside the request, so it has no file in workers/."""

from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from netdef_ci.github.retry.base import RetryBase
from netdef_ci.github.retry.command import RetryCommand
from netdef_ci.github.retry.comment import RetryComment
from netdef_ci.helpers.db import session_scope
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.jobs.registry import job_handler

Response = tuple[int, str]


def _build(session: Session, kind: str, payload: dict[str, Any]) -> RetryBase:
    return {RetryCommand.KIND: RetryCommand, RetryComment.KIND: RetryComment}[kind](session, payload)


def run(session: Session, kind: str, payload: dict[str, Any]) -> Response:
    """`retry_execution` job: the retry itself, serialized with the executions of the same pull request."""
    retry = _build(session, kind, payload)
    suite = retry.stage.check_suite if retry.stage is not None else None
    if suite is None or suite.pull_request_id is None:
        output = retry.start()
    else:
        with pull_request_lock(suite.pull_request_id):
            # The rows were read before waiting for the lock, possibly before another retry of this suite committed:
            # end that transaction (nothing was written), forget the loaded rows and decide again from the database.
            session.rollback()
            session.expire_all()
            retry = _build(session, kind, payload)
            output = retry.start()
    retry.log.info("Retry (%s) finished with %s", kind, output)
    return output


@job_handler("retry_execution")
def retry_execution_job(kind: str, payload: dict[str, Any]) -> None:
    with session_scope() as session:
        run(session, kind, payload)
