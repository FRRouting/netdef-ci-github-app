#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/summary.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Stage summary/state machine driven by job updates (port of Build::Summary)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session, object_session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.logs import Log
from netdef_ci.models import CiJob, Stage, StageConfiguration
from netdef_ci.services.message_formatter import MessageFormatter


class Summary:
    def __init__(self, job: CiJob, agent: str = "Github") -> None:
        session = object_session(job)
        assert session is not None
        session.refresh(job)
        self.session: Session = session
        self.job = job
        assert job.check_suite is not None and job.check_suite.pull_request is not None
        self.check_suite = job.check_suite
        self.github = container.github(self.check_suite)
        self.agent = agent
        self.settings = get_settings()
        self.log = Log("github_build_summary", job.check_suite.pull_request.github_pr_id)
        self.formatter = MessageFormatter()

    def build_summary(self) -> None:
        current = self.job.stage or self._fetch_parent_stage()
        self.log.info("build_summary: stage %s job %s", current.id, self.job.id)
        if current.state == Status.CANCELLED:
            return
        self._update_summary(current)
        self._finished_summary(current)
        self._must_cancel_next_stages(current)
        self._must_continue_next_stage(current)
        self._must_update_previous_stage(current)

    # ------------------------------------------------------------------
    def _stages_by_position(self, *conditions) -> list[Stage]:
        stmt = (
            select(Stage)
            .join(StageConfiguration, Stage.stage_configuration_id == StageConfiguration.id)
            .where(Stage.check_suite_id == self.check_suite.id, *conditions)
            .order_by(Stage.id)
        )
        return list(self.session.scalars(stmt))

    def _must_update_previous_stage(self, current: Stage) -> None:
        position = int(current.configuration.position or 0) if current.configuration else 0
        stages = self._stages_by_position(
            StageConfiguration.position >= 0,
            StageConfiguration.position < position,
            Stage.status.in_([Status.IN_PROGRESS, Status.QUEUED]),
        )
        for stage in stages:
            if stage.is_running():
                continue
            self.log.info("must_update_previous_stage: %s", stage.id)
            self._finished_stage_summary(stage)

    def _must_cancel_next_stages(self, current: Stage) -> None:
        if current.state not in (Status.FAILURE, Status.SKIPPED, Status.CANCELLED):
            return
        config = current.configuration
        if config is None or not config.mandatory:
            return
        for stage in self._stages_by_position(StageConfiguration.position >= (config.position or 0) + 1):
            self._cancel_next_stage(stage)

    def _must_continue_next_stage(self, current: Stage) -> None:
        if not current.is_finished() or current.state in (Status.FAILURE, Status.SKIPPED, Status.CANCELLED):
            return
        if current.configuration is None:
            return
        found = self._stages_by_position(StageConfiguration.position == (current.configuration.position or 0) + 1)
        next_stage = found[0] if found else None
        if next_stage is None or next_stage.is_finished():
            return
        self._update_summary(next_stage)

    def _cancel_next_stage(self, pending: Stage) -> None:
        url = self.settings.browse_url(pending.check_suite.bamboo_ci_ref if pending.check_suite else None)
        output = {
            "title": f"{pending.name} summary",
            "summary": f"The previous stage failed and the remaining tests will be canceled.\nDetails at [{url}]({url}).",
        }
        self.log.info("cancelling_next_stage - pending_stage: %s", pending.id)
        pending.cancelled(self.github, output=output)
        for job in pending.all_jobs():
            job.cancelled(self.github)

    def _finished_summary(self, stage: Stage) -> None:
        if self.job.state == Status.IN_PROGRESS or stage.is_running():
            return
        self._finished_stage_summary(stage)

    def _finished_stage_summary(self, stage: Stage) -> None:
        url = self.settings.browse_url(self.check_suite.bamboo_ci_ref)
        output = {"title": f"{stage.name} summary", "summary": self.formatter.summary_with_footer(stage, url)}
        if not stage.failed_jobs():
            self.log.warning("Stage: %s finished - success", stage.name)
            stage.success(self.github, output=output, agent=self.agent)
        else:
            self.log.warning("Stage: %s finished - failure", stage.name)
            stage.failure(self.github, output=output, agent=self.agent)
        stage.update_execution_time()

    def _update_summary(self, stage: Stage) -> None:
        url = self.settings.browse_url(self.check_suite.bamboo_ci_ref)
        output = {"title": f"{stage.name} summary", "summary": self.formatter.summary_with_footer(stage, url)}
        self.log.warning("Updating stage: %s to in_progress", stage.name)
        stage.in_progress(self.github, output=output)
        stage.update_output(self.github, output=output)

    def _fetch_parent_stage(self) -> Stage:
        jobs = container.bamboo().running_plan(self.check_suite.bamboo_ci_ref)
        info = next((j for j in jobs if j["name"] == self.job.name), None)
        if info is None:
            raise LookupError(f"job {self.job.name!r} not found in running plan {self.check_suite.bamboo_ci_ref}")
        config = self.session.scalars(
            select(StageConfiguration)
            .where(StageConfiguration.bamboo_stage_name == info["stage"])
            .order_by(StageConfiguration.id)
        ).first()
        stage = self.session.scalars(
            select(Stage)
            .where(Stage.check_suite_id == self.check_suite.id, Stage.name == info["stage"])
            .order_by(Stage.id)
        ).first()
        if stage is None:
            stage = Stage(
                check_suite_id=self.check_suite.id,
                name=info["stage"],
                stage_configuration_id=config.id if config else None,
                status=Status.QUEUED,
            )
            self.session.add(stage)
            self.session.commit()
        self.log.info("fetch_parent_stage - stage: %s", stage.id)
        self.job.stage_id = stage.id
        self.session.commit()
        return stage
