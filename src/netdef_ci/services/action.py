#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/action.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Creates the stages and jobs of an execution and the GitHub check runs (port of Build::Action)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session, object_session

from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, Stage, StageConfiguration
from netdef_ci.services.skip_old_tests import SkipOldTests


class Action:
    def __init__(self, check_suite: CheckSuite, github, jobs: list[dict], name: str | None) -> None:  # noqa: ANN001
        self.check_suite = check_suite
        self.github = github
        self.jobs = jobs
        self.name = name
        self.settings = get_settings()
        session = object_session(check_suite)
        assert session is not None and check_suite.pull_request is not None
        self.session: Session = session
        self.stage_configs = list(session.scalars(select(StageConfiguration).order_by(StageConfiguration.id)))
        self.log = Log("github_build_action", check_suite.pull_request.github_pr_id)
        self.log.warning(">>>> Building action to CheckSuite %s", check_suite.id)

    def create_summary(self, rerun: bool = False) -> None:
        SkipOldTests(self.check_suite).skip_old_tests()
        for stage_config in self.stage_configs:
            self._create_check_run_stage(stage_config)
        self.log.info("jobs - %s", self.jobs)
        self._create_jobs(rerun)
        self._create_timeout_worker()

    # ------------------------------------------------------------------
    def _create_jobs(self, rerun: bool) -> None:
        for job in self.jobs:
            ci_job = self._create_ci_job(job)
            if ci_job is None:
                continue
            if rerun:
                stage = ci_job.stage
                if stage is None or stage.configuration is None or not stage.configuration.can_retry:
                    continue
                url = self.settings.browse_url(ci_job.job_ref)
                ci_job.enqueue(self.github, {"title": ci_job.name, "summary": f"Details at [{url}]({url})"})
            else:
                ci_job.create_check_run()
            self._stage_with_start_in_progress(ci_job)

    def _create_timeout_worker(self) -> None:
        self.log.info("TimeoutExecution scheduled for check suite %s", self.check_suite.id)
        jobs_queue.enqueue(
            self.session,
            "timeout_execution",
            [self.check_suite.id],
            queue="timeout_execution",
            delay_seconds=self.settings.timeout_check_minutes * 60,
        )

    def _stage_with_start_in_progress(self, ci_job: CiJob) -> None:
        stage = ci_job.stage
        if stage is None or stage.configuration is None or not stage.configuration.start_in_progress:
            return
        ci_job.in_progress(self.github)
        stage.in_progress(self.github, output={})

    def _create_ci_job(self, job: dict) -> CiJob | None:
        config = self.session.scalars(
            select(StageConfiguration).where(StageConfiguration.bamboo_stage_name == job.get("stage")).order_by(StageConfiguration.id)
        ).first()
        if config is None:
            return None
        stage = self.session.scalars(
            select(Stage).where(Stage.check_suite_id == self.check_suite.id, Stage.name == self._stage_name(config)).order_by(Stage.id)
        ).first()
        self.log.info("create_jobs - %s -> stage %s", job, stage.id if stage else None)
        ci_job = CiJob(check_suite_id=self.check_suite.id, name=job.get("name"), job_ref=job.get("job_ref"), stage=stage)
        if not ci_job.name or not ci_job.job_ref:
            self.log.error("Job without name/job_ref ignored: %s", job)  # model validations in the Ruby app
            return None
        self.session.add(ci_job)
        self.session.commit()
        return ci_job

    def _create_check_run_stage(self, stage_config: StageConfiguration) -> None:
        self.log.info("create_check_run_stage - %s - %s", stage_config.github_check_run_name, self.name)
        stage = self.session.scalars(
            select(Stage).where(Stage.name == self._stage_name(stage_config), Stage.check_suite_id == self.check_suite.id).order_by(Stage.id)
        ).first()
        if stage is None:
            self._create_stage(stage_config)
            return
        if stage.configuration is None or not stage.configuration.can_retry:
            return
        stage.enqueue(self.github, output=self._initial_output(stage))

    def _create_stage(self, stage_config: StageConfiguration) -> Stage:
        stage = Stage(
            check_suite_id=self.check_suite.id,
            stage_configuration_id=stage_config.id,
            status=Status.QUEUED,
            name=self._stage_name(stage_config),
        )
        self.session.add(stage)
        self.session.commit()
        url = self.settings.browse_url(self.check_suite.bamboo_ci_ref)
        output = {"title": f"{stage.name} summary", "summary": f"Uninitialized stage\nDetails at [{url}]({url})"}
        stage.enqueue(self.github, output=output)
        if stage_config.start_in_progress:
            stage.in_progress(self.github)
        return stage

    def _initial_output(self, stage: Stage) -> dict[str, str]:
        url = self.settings.browse_url(self.check_suite.bamboo_ci_ref)
        return {"title": f"{stage.name} summary", "summary": f"Details at [{url}]({url})"}

    def _stage_name(self, stage_config: StageConfiguration) -> str:
        assert self.check_suite.pull_request is not None
        if len(self.check_suite.pull_request.plans) == 1 or not (self.name or "").strip():
            return stage_config.github_check_run_name
        if not self.settings.multi_plan:
            return stage_config.github_check_run_name
        return f"{stage_config.github_check_run_name} - {self.name}"

