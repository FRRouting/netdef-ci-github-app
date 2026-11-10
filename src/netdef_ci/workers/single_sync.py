#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/single_sync.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Synchronizes one Bamboo build with the database, run by hand (port of workers/single_sync.rb)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.helpers.config import get_settings
from netdef_ci.models import CheckSuite, CiJob


def single_sync(session: Session, bamboo_ci: str, out: Any = print) -> bool:
    check_suite = session.scalars(select(CheckSuite).where(CheckSuite.bamboo_ci_ref == bamboo_ci).limit(1)).first()
    if check_suite is None:
        out("Please inform the CI that you would like to sync like the example: TESTING-GITHUBCHECKBETA-82")
        return False
    result = container.bamboo().get_status(bamboo_ci) or {}
    github = container.github(check_suite)
    settings = get_settings()
    for stage in (result.get("stages") or {}).get("stage") or []:
        for item in (stage.get("results") or {}).get("result") or []:
            ref = item.get("buildResultKey")
            ci_job = session.scalars(
                select(CiJob).where(CiJob.job_ref == ref, CiJob.check_suite_id == check_suite.id).limit(1)
            ).first()
            if ci_job is None:
                ci_job = CiJob(
                    check_suite_id=check_suite.id, name=(item.get("plan") or {}).get("shortName"), job_ref=ref
                )
                session.add(ci_job)
                session.commit()
                out(f">>> Creating CiJob {ci_job.id}, status: {item.get('state')}")
            elif ci_job.is_finished():
                continue
            url = settings.browse_url(ci_job.job_ref)
            output = {
                "title": ci_job.name,
                "summary": f"Details at [{url}]({url})\nUnfortunately we were unable to access the execution results.",
            }
            state = item.get("state")
            if state == "Unknown":
                ci_job.cancelled(github, output)
            elif state == "Failed":
                ci_job.failure(github, output)
            elif state == "Successful":
                ci_job.success(github, output)
            else:
                out("Ignored")
    return True
