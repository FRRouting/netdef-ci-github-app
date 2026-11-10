#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/ci_job_status.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Rebuilds the summary of a check suite after Bamboo job callbacks (port of workers/ci_job_status.rb)."""

from __future__ import annotations

from sqlalchemy.orm import Session

from netdef_ci.github.build.summary import Summary
from netdef_ci.github.plan_execution.finished import schedule_finished
from netdef_ci.helpers.db import session_scope
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CiJob


def ci_job_status(session: Session, bamboo_ci_ref: str, ci_job_id: int) -> None:
    log = Log("ci_job_status")
    log.info("CiJobStatus::Update: check suite %s -> '%s'", bamboo_ci_ref, ci_job_id)
    job = session.get(CiJob, ci_job_id)
    if job is None:
        raise LookupError(f"CiJob {ci_job_id} not found")
    Summary(job).build_summary()  # reloads the job; its changes stay in this session's identity map
    if not job.is_finished():
        return
    log.info("Github::PlanExecution::Finished: '%s'", bamboo_ci_ref)
    schedule_finished(session, {"bamboo_ref": bamboo_ci_ref})


@job_handler("ci_job_status")
def ci_job_status_job(bamboo_ci_ref: str, ci_job_id: int) -> None:
    with session_scope() as session:
        ci_job_status(session, bamboo_ci_ref, ci_job_id)
