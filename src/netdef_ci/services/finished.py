#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/finished.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""End-of-execution reconciliation with Bamboo (port of PlanExecution::Finished)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, Stage, StageConfiguration
from netdef_ci.services.summary import Summary

Response = tuple[int, str]


class Finished:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        ref, suite_id = payload.get("bamboo_ref"), payload.get("check_suite_id")
        conditions = []
        if ref is not None:
            conditions.append(CheckSuite.bamboo_ci_ref == ref)
        if suite_id is not None:
            conditions.append(CheckSuite.id == suite_id)
        # Ruby's `where(ref: nil).or(where(id: nil))` also matched suites without a Bamboo ref; only given keys are used here.
        self.check_suite: CheckSuite | None = (
            session.scalars(select(CheckSuite).where(or_(*conditions)).order_by(CheckSuite.id.desc()).limit(1)).first()
            if conditions
            else None
        )
        self.hanged = bool(payload.get("hanged") or False)
        self.log = Log("github_plan_execution_finished")
        self.result: dict[str, Any] | None = None

    def finished(self) -> Response:
        if self.check_suite is None:
            return 404, "Check Suite not found"
        self.log.info(">>> Check Suite: %s (%s)", self.check_suite.id, self.check_suite.bamboo_ci_ref)
        self.result = container.bamboo().get_status(self.check_suite.bamboo_ci_ref or "")
        build_status = self.fetch_build_status()
        if build_status is None:
            self.log.error("Bamboo status unavailable for %s; nothing changed", self.check_suite.bamboo_ci_ref)
            return 503, "Bamboo unavailable"
        self.log.info(">>> build_status: %s. Hanged? %s", build_status, self.hanged)
        if self._in_progress(build_status) and not self.hanged:
            return 200, "Still running"
        self._check_stages()
        self._clear_deleted_jobs()
        self._update_all_stages()
        return 200, "Finished"

    def fetch_build_status(self) -> dict[str, Any] | None:
        assert self.check_suite is not None
        return container.bamboo().build_status(self.check_suite.bamboo_ci_ref or "")

    # ------------------------------------------------------------------
    @staticmethod
    def _stopped(status: dict[str, Any]) -> bool:
        return "message" in status and "finished" not in status

    def _hanged(self, status: dict[str, Any]) -> bool:
        if self._stopped(status):
            return True
        try:
            return float((status.get("progress") or {}).get("percentageCompleted") or 0) >= 2.0
        except TypeError, ValueError:
            return False

    def _in_progress(self, status: dict[str, Any]) -> bool:
        self.log.info(">>> ci_stopped?: %s ci_hanged?: %s", self._stopped(status), self._hanged(status))
        if self._hanged(status):
            return False
        return str(status.get("currentStage") or "").lower() != "final"

    # ------------------------------------------------------------------
    def _update_all_stages(self) -> None:
        assert self.check_suite is not None
        stages = list(
            self.session.scalars(
                select(Stage)
                .join(StageConfiguration, Stage.stage_configuration_id == StageConfiguration.id)
                .where(Stage.check_suite_id == self.check_suite.id)
                .order_by(Stage.id)
            )
        )
        if not stages:
            return
        last_stage = max(
            stages,
            key=lambda s: s.configuration.position if s.configuration and s.configuration.position is not None else -1,
        )
        jobs = last_stage.all_jobs()
        if not jobs:
            return
        self._build_summary(jobs[-1])

    def _clear_deleted_jobs(self) -> None:
        assert self.check_suite is not None
        github = container.github(self.check_suite)
        for ci_job in self.check_suite.running_jobs():
            ci_job.skipped(github)

    def _check_stages(self) -> None:
        assert self.check_suite is not None
        github = container.github(self.check_suite)
        result = self.result
        if not result or 400 <= int(result.get("status-code") or 0) <= 500:
            return
        for stage in (result.get("stages") or {}).get("stage") or []:
            for item in (stage.get("results") or {}).get("result") or []:
                ci_job = self.session.scalars(
                    select(CiJob)
                    .where(CiJob.job_ref == item.get("buildResultKey"), CiJob.check_suite_id == self.check_suite.id)
                    .limit(1)
                ).first()
                self._update_stage_status(ci_job, item, github)

    def _update_stage_status(self, ci_job: CiJob | None, result: dict[str, Any], github: Any) -> None:
        if ci_job is None or (ci_job.is_finished() and ci_job.job_ref is not None):
            return
        self._update_ci_job_status(github, ci_job, result.get("state"))

    def _update_ci_job_status(self, github: Any, ci_job: CiJob, state: str | None) -> None:
        if ci_job.job_ref is None:
            ci_job.enqueue(github)
        url = get_settings().browse_url(ci_job.job_ref)
        output = {
            "title": ci_job.name,
            "summary": f"Details at [{url}]({url})\nUnfortunately we were unable to access the execution results.",
        }
        slack = container.slack()
        if state == "Unknown":
            ci_job.cancelled(github, output=output, agent="WatchDog")
            slack.notify_cancelled(ci_job)
        elif state == "Failed":
            ci_job.failure(github, output=output, agent="WatchDog")
            slack.notify_errors(ci_job)
        elif state == "Successful":
            ci_job.success(github, output=output, agent="WatchDog")
            slack.notify_success(ci_job)
        else:
            self.log.info("Ignored state %r for job %s", state, ci_job.job_ref)
        self._build_summary(ci_job)

    def _build_summary(self, ci_job: CiJob) -> None:
        Summary(ci_job, agent="WatchDog").build_summary()
        self._finished_execution(ci_job.check_suite)

    @staticmethod
    def _finished_execution(check_suite: CheckSuite | None) -> bool:
        if check_suite is None or check_suite.pull_request is None:
            return False
        if not check_suite.pull_request.current_execution(check_suite) or not check_suite.is_finished():
            return False
        container.slack().execution_finished_notification(check_suite)
        return True
