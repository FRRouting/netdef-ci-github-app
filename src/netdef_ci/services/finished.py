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
from netdef_ci.enums import RUNNING_STATUSES
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, Stage, StageConfiguration
from netdef_ci.services.summary import Summary

Response = tuple[int, str]


class BambooUnavailable(Exception):
    """Bamboo did not answer: the `finished_execution` job is retried with back-off."""


def schedule_finished(session: Session, payload: dict[str, Any]) -> Response:
    """Schedule the end-of-execution reconciliation (Bamboo, GitHub and Slack calls) as a `finished_execution` job on
    the numeric queue of the pull request, the queue of its `ci_job_status` jobs, which it must not race.

    Both the `finished` callback of Bamboo and the status job of a finished CI job ask for it: a pending request for
    the same suite is replaced, so the two triggers of one execution end usually run it once."""
    check_suite = Finished(session, payload).check_suite
    if check_suite is None:
        return 404, "Check Suite not found"
    pull_request = check_suite.pull_request
    queue = pull_request.github_pr_id % 10 if pull_request is not None else 0
    jobs_queue.replace_pending(
        session, "finished_execution", f"suite-{check_suite.id}", [payload], queue=queue, delay_seconds=0
    )
    return 200, "Finished scheduled"


class Finished:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        ref, suite_id = payload.get("bamboo_ref"), payload.get("check_suite_id")
        conditions = []
        if ref is not None:
            conditions.append(CheckSuite.bamboo_ci_ref == ref)
        if suite_id is not None:
            conditions.append(CheckSuite.id == suite_id)
        # Only the keys that were given take part in the lookup.
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
        if not self.check_suite.bamboo_ci_ref:
            # The Bamboo plan was never started for this suite: there is nothing to ask Bamboo, treat it as stopped.
            self.log.warning(
                "Check Suite %s has no Bamboo reference; closing it without calling Bamboo", self.check_suite.id
            )
            self.result = None
            build_status: dict[str, Any] | None = {"message": "No Bamboo execution for this check suite"}
        else:
            self.result = container.bamboo().get_status(self.check_suite.bamboo_ci_ref)
            build_status = self.fetch_build_status()
        if build_status is None:
            self.log.error("Bamboo status unavailable for %s; nothing changed", self.check_suite.bamboo_ci_ref)
            return 503, "Bamboo unavailable"
        self.log.info(">>> build_status: %s. Hanged? %s", build_status, self.hanged)
        if self._in_progress(build_status) and not self.hanged:
            return 200, "Still running"
        # Every job is updated first (one commit); the summaries are then rebuilt once per affected stage instead of
        # once per job, which cost GitHub, Bamboo and Slack calls for each of the hundreds of jobs of an execution.
        touched = self._check_stages() + self._clear_deleted_jobs()
        self._update_all_stages(touched)
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
    def _update_all_stages(self, touched: list[CiJob]) -> None:
        """Rebuild the summary of each stage that has an updated job, and of the last stage, in pipeline order (a
        failed mandatory stage cancels the next ones before they are visited). A stage that is already closed and
        had no update is left alone: rebuilding it would reopen and close its check run again."""
        assert self.check_suite is not None
        stages = list(
            self.session.scalars(
                select(Stage)
                .join(StageConfiguration, Stage.stage_configuration_id == StageConfiguration.id)
                .where(Stage.check_suite_id == self.check_suite.id)
                .order_by(Stage.id)
            )
        )

        def position(stage: Stage) -> int:
            config = stage.configuration
            return config.position if config is not None and config.position is not None else -1

        # The job each summary starts from: the last updated job of the stage (the last job for the last stage).
        targets: dict[int, CiJob] = {}
        orphans: list[CiJob] = []  # jobs without a stage: Summary finds it through Bamboo
        for job in touched:
            if job.stage_id is None:
                orphans.append(job)
            else:
                targets[job.stage_id] = job
        if stages:
            last_stage = max(stages, key=position)
            if last_stage.id not in targets and last_stage.state in RUNNING_STATUSES:
                jobs = last_stage.all_jobs()
                if jobs:
                    targets[last_stage.id] = jobs[-1]
        by_id = {stage.id: stage for stage in stages}
        ordered = sorted(
            targets, key=lambda stage_id: (position(by_id[stage_id]), stage_id) if stage_id in by_id else (-2, stage_id)
        )
        starts = orphans + [targets[stage_id] for stage_id in ordered]
        for job in starts:
            Summary(job, agent="WatchDog").build_summary()
        self._finished_execution(self.check_suite)

    def _clear_deleted_jobs(self) -> list[CiJob]:
        assert self.check_suite is not None
        github = container.github(self.check_suite)
        skipped = self.check_suite.running_jobs()
        for ci_job in skipped:
            ci_job.skipped(github, commit=False)
        self.session.commit()
        return skipped

    def _check_stages(self) -> list[CiJob]:
        """Apply Bamboo's final state to the jobs that are still open; returns the jobs that changed."""
        assert self.check_suite is not None
        result = self.result
        if not result or 400 <= int(result.get("status-code") or 0) <= 500:
            return []
        github = container.github(self.check_suite)
        jobs: dict[str | None, CiJob] = {}
        for ci_job in self.session.scalars(
            select(CiJob).where(CiJob.check_suite_id == self.check_suite.id).order_by(CiJob.id)
        ):
            jobs.setdefault(ci_job.job_ref, ci_job)
        updated: list[tuple[CiJob, str | None]] = []
        for stage in (result.get("stages") or {}).get("stage") or []:
            for item in (stage.get("results") or {}).get("result") or []:
                job = jobs.get(item.get("buildResultKey"))
                if job is None or job.is_finished():
                    continue
                self._update_ci_job_status(github, job, item.get("state"))
                updated.append((job, item.get("state")))
        self.session.commit()
        slack = container.slack()
        for ci_job, state in updated:  # after the commit: notify only what was stored
            if state == "Unknown":
                slack.notify_cancelled(ci_job)
            elif state == "Failed":
                slack.notify_errors(ci_job)
            elif state == "Successful":
                slack.notify_success(ci_job)
        return [ci_job for ci_job, _state in updated]

    def _update_ci_job_status(self, github: Any, ci_job: CiJob, state: str | None) -> None:
        url = get_settings().browse_url(ci_job.job_ref)
        output = {
            "title": ci_job.name,
            "summary": f"Details at [{url}]({url})\nUnfortunately we were unable to access the execution results.",
        }
        if state == "Unknown":
            ci_job.cancelled(github, output=output, agent="WatchDog", commit=False)
        elif state == "Failed":
            ci_job.failure(github, output=output, agent="WatchDog", commit=False)
        elif state == "Successful":
            ci_job.success(github, output=output, agent="WatchDog", commit=False)
        else:
            self.log.info("Ignored state %r for job %s", state, ci_job.job_ref)

    @staticmethod
    def _finished_execution(check_suite: CheckSuite | None) -> bool:
        if check_suite is None or check_suite.pull_request is None:
            return False
        if not check_suite.pull_request.current_execution(check_suite) or not check_suite.is_finished():
            return False
        container.slack().execution_finished_notification(check_suite)
        return True
