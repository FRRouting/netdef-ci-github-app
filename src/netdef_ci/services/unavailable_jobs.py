#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/unavailable_jobs.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Skips jobs that were removed from the Bamboo plan (port of Build::UnavailableJobs)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import object_session

from netdef_ci import container
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob


class UnavailableJobs:
    def __init__(self, check_suite: CheckSuite | None) -> None:
        self.check_suite = check_suite
        self.log = Log("github_unavailable_jobs")
        self.github = container.github(check_suite) if check_suite is not None else None

    def update(self, new_check_suite: CheckSuite | None = None) -> None:
        if self.check_suite is None:
            return
        session = object_session(self.check_suite)
        assert session is not None
        assert self.github is not None
        self.log.warning(">>> Check Unavailable Jobs")
        running = [j["job_ref"] for j in container.bamboo().running_plan(self.check_suite.bamboo_ci_ref)]
        stmt = (
            select(CiJob)
            .where(CiJob.check_suite_id == self.check_suite.id, CiJob.job_ref.not_in(running))
            .order_by(CiJob.id)
        )
        for job in list(session.scalars(stmt)):
            job.skipped(
                self.github,
                output={
                    "title": job.name,
                    "summary": "This check has been removed from the CI execution plan and in your next commit or "
                    "rebase it will not be executed and will not appear in the Check Run list.",
                },
            )
            if new_check_suite is not None:
                job.check_suite_id = new_check_suite.id
                session.commit()
