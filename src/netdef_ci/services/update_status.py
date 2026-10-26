#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/update_status.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Job status callback sent by Bamboo to `POST /update/status` (port of Github::UpdateStatus)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CiJob, TopotestFailure

Response = tuple[int, str]


class UpdateStatus:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        self.status = payload.get("status")
        self.reference = payload.get("bamboo_ref") or "invalid_reference"
        self.job: CiJob | None = None
        if payload.get("bamboo_ref"):
            self.job = session.scalars(select(CiJob).where(CiJob.job_ref == payload["bamboo_ref"]).order_by(CiJob.id).limit(1)).first()
        self.check_suite = self.job.check_suite if self.job else None
        self.failures = payload.get("failures") or []
        output = payload.get("output")
        self.summary = (output.get("summary") if isinstance(output, dict) else None) if "output" in payload else ""
        pr_id = self.check_suite.pull_request.github_pr_id if self.check_suite and self.check_suite.pull_request else None
        self.log = Log("github_update_status", pr_id)

    def update(self) -> Response:
        self.log.info("Updating status for job: %s with status: %s", self.reference, self.status)
        if self.job is None:
            self.log.error("CI JOB not found: '%s'", self.reference)
            return 404, "CI JOB not found"
        if self.job.state == Status.QUEUED and self.status != "in_progress" and self.job.name != "Checkout Code":
            return 304, "Not Modified"
        if self.job.state == Status.IN_PROGRESS and self.status not in ("success", "failure"):
            return 304, "Not Modified"
        github = container.github(self.job.check_suite)
        return self._update_status(github)

    # ------------------------------------------------------------------
    def _update_status(self, github: Any) -> Response:
        job = self.job
        assert job is not None
        try:
            if self.status == "in_progress":
                job.in_progress(github)
            elif self.status == "success":
                job.success(github)
                job.update_execution_time()
            else:
                self._failure(github)
                job.update_execution_time()
                job.summary = self.summary
                self.session.commit()
            check_suite = job.check_suite
            assert check_suite is not None and check_suite.pull_request is not None
            if not check_suite.pull_request.current_execution(check_suite):
                return 200, "Success"
            self._insert_new_job()
            return 200, "Success"
        except Exception as error:  # noqa: BLE001 - the Ruby handler answered 500 for any StandardError
            self.session.rollback()
            self.log.error("%s %s", type(error).__name__, error)
            return 500, "Internal Server Error"

    def _failure(self, github: Any) -> None:
        job = self.job
        assert job is not None
        job.failure(github)
        if isinstance(self.failures, list) and self.failures:
            for failure in self.failures:
                self.session.add(
                    TopotestFailure(
                        ci_job_id=job.id,
                        test_suite=failure.get("suite"),
                        test_case=failure.get("case"),
                        message=failure.get("message"),
                        execution_time=int(failure.get("execution_time") or 0),
                    )
                )
            self.session.commit()
            return
        jobs_queue.enqueue(
            self.session, "fetch_topotest_failures", [job.id, 1], queue="fetch_topotest_failures", delay_seconds=300
        )

    def _insert_new_job(self) -> None:
        job = self.job
        assert job is not None and job.check_suite is not None and job.check_suite.pull_request is not None
        queue = job.check_suite.pull_request.github_pr_id % 10
        ref = job.check_suite.bamboo_ci_ref or ""
        self.log.info("Inserting new job for queue %s to update job %s (%s)", queue, job.id, ref)
        # Debounce: only the last callback within STATUS_DEBOUNCE_SECONDS rebuilds the stage summary.
        jobs_queue.replace_pending(
            self.session, "ci_job_status", ref, [ref, job.id], queue=queue, delay_seconds=get_settings().status_debounce_seconds
        )
