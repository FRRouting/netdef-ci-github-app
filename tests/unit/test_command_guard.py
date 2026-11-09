#  SPDX-License-Identifier: BSD-2-Clause
#
#  tests/unit/test_command_guard.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from netdef_ci.db import utcnow
from netdef_ci.models import AuditRetry, Job
from netdef_ci.services.command_guard import CommandGuard
from tests import factories as f


def test_admitted_command_jobs_are_committed_with_the_pull_request_key(session) -> None:
    w = f.World(session)
    guard = CommandGuard(session, w.pr.id)
    with guard.admission() as refused:
        assert refused is None
        guard.enqueue("retry_execution", ["command", {}], queue="retry_execution", delay_seconds=3)
    session.rollback()  # the jobs were committed when the admission ended
    job = session.scalars(select(Job)).one()
    assert (job.max_attempts, job.dedupe_key) == (1, f"ci-command:{w.pr.id}")


def test_a_pending_or_running_command_job_refuses_the_next_command(session) -> None:
    w = f.World(session)
    guard = CommandGuard(session, w.pr.id)
    with guard.admission():
        guard.enqueue("create_execution_by_comment", [w.pr.id, {}, w.plan.id, None], queue="q")
    job = session.scalars(select(Job)).one()
    job.locked_at = utcnow()  # running
    session.commit()
    with guard.admission() as refused:
        assert refused == (409, "Another ci:retry/ci:rerun is in progress for this pull request")
    with CommandGuard(session, w.pr.id + 1).admission() as refused:
        assert refused is None  # other pull requests are not affected


@pytest.mark.parametrize(("age", "refused"), [(10, True), (120, False)])
def test_a_command_started_within_the_cooldown_refuses_the_next_one(session, age, refused) -> None:
    w = f.World(session)
    session.add(
        AuditRetry(check_suite_id=w.suite.id, retry_type="partial", created_at=utcnow() - timedelta(seconds=age))
    )
    session.commit()
    with CommandGuard(session, w.pr.id).admission() as refusal:
        assert (refusal is not None) is refused


def test_an_error_while_scheduling_rolls_the_admission_back(session) -> None:
    w = f.World(session)
    guard = CommandGuard(session, w.pr.id)
    with pytest.raises(RuntimeError), guard.admission():
        guard.enqueue("retry_execution", [], queue="q")
        raise RuntimeError("boom")
    assert session.scalars(select(Job)).all() == []
