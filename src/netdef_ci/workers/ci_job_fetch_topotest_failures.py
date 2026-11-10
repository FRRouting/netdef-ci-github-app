#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/ci_job_fetch_topotest_failures.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Stores the topotest failures of a failed CI job (port of workers/ci_job_fetch_topotest_failures.rb)."""

from __future__ import annotations

from sqlalchemy.orm import Session

from netdef_ci.github.topotest_failures.retrieve_error import retrieve_failures
from netdef_ci.helpers.db import session_scope
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CiJob, TopotestFailure


def fetch_topotest_failures(session: Session, ci_job_id: int, count: int) -> None:
    job = session.get(CiJob, ci_job_id)
    if job is None:
        raise LookupError(f"CiJob {ci_job_id} not found")
    failures = retrieve_failures(job)
    if count > 3:
        return
    if not failures:
        count += 1
        jobs_queue.enqueue(
            session,
            "fetch_topotest_failures",
            [job.id, count],
            queue="fetch_topotest_failures",
            delay_seconds=5 * count * 60,
        )
        return
    for failure in failures:
        session.add(
            TopotestFailure(
                ci_job_id=job.id,
                test_suite=failure["suite"] or "",
                test_case=failure["case"] or "",
                message=failure["message"],
                execution_time=failure["execution_time"],
            )
        )
    session.commit()


@job_handler("fetch_topotest_failures")
def fetch_topotest_failures_job(ci_job_id: int, count: int) -> None:
    with session_scope() as session:
        fetch_topotest_failures(session, ci_job_id, count)
