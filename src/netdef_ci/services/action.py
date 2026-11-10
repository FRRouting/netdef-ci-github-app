#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/action.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Creates the stages and jobs of an execution and the GitHub check runs (port of Build::Action)."""

from __future__ import annotations

from sqlalchemy import exists, select
from sqlalchemy.orm import Session, object_session

from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, Job, Stage, StageConfiguration
from netdef_ci.services.skip_old_tests import SkipOldTests


def timeout_dedupe_key(check_suite_id: int) -> str:
    """Marks the `timeout_execution` job of a suite, so a resumed setup does not start a second chain of them."""
    return f"suite-{check_suite_id}"


class Action:
    def __init__(self, check_suite: CheckSuite, github, jobs: list[dict], name: str | None) -> None:
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

    def create_summary(self, rerun: bool = False, *, resume: bool = False) -> None:
        """`resume` completes a setup that failed part-way (`setup_github_checks` job): an existing stage only gets what
        it lacks (its check run, or `in_progress` when its configuration starts in progress), existing CI jobs (same
        `job_ref`) are not created again and the timeout job is not scheduled twice. Missing stages are created as
        usual."""
        SkipOldTests(self.check_suite).skip_old_tests()
        for stage_config in self.stage_configs:
            self._create_check_run_stage(stage_config, resume)
        self.log.info("jobs - %s", self.jobs)
        self._create_jobs(rerun, resume)
        if not (resume and self._timeout_scheduled()):
            self._create_timeout_worker()

    # ------------------------------------------------------------------
    def _create_jobs(self, rerun: bool, resume: bool = False) -> None:
        # Hundreds of jobs per execution: look configurations and stages up in memory and commit in two batches
        # (the jobs, then their audit entries) instead of a round trip and a commit per job.
        configs: dict[str, StageConfiguration] = {}
        for config in self.stage_configs:
            configs.setdefault(config.bamboo_stage_name, config)
        stages: dict[str, Stage] = {}
        for stage in self.session.scalars(
            select(Stage).where(Stage.check_suite_id == self.check_suite.id).order_by(Stage.id)
        ):
            stages.setdefault(stage.name, stage)
        existing: dict[str | None, CiJob] = {}
        if resume:
            for stored in self.session.scalars(
                select(CiJob).where(CiJob.check_suite_id == self.check_suite.id).order_by(CiJob.id)
            ):
                existing.setdefault(stored.job_ref, stored)
        new_jobs = [job for job in self.jobs if job.get("job_ref") not in existing]
        created = [ci_job for job in new_jobs if (ci_job := self._create_ci_job(job, configs, stages)) is not None]
        self.session.add_all(created)
        self.session.commit()
        # Existing jobs that the failed run left queued still need their start-in-progress stage announced.
        queued = [stored for stored in existing.values() if stored.state == Status.QUEUED]
        for ci_job in created:
            if rerun:
                job_stage = ci_job.stage
                if job_stage is None or job_stage.configuration is None or not job_stage.configuration.can_retry:
                    continue
            ci_job.create_check_run(commit=False)
            queued.append(ci_job)
        self.session.commit()
        for ci_job in queued:
            self._stage_with_start_in_progress(ci_job)

    def _create_timeout_worker(self) -> None:
        self.log.info("TimeoutExecution scheduled for check suite %s", self.check_suite.id)
        jobs_queue.enqueue(
            self.session,
            "timeout_execution",
            [self.check_suite.id],
            queue="timeout_execution",
            delay_seconds=self.settings.timeout_check_minutes * 60,
            dedupe_key=timeout_dedupe_key(self.check_suite.id),
        )

    def _timeout_scheduled(self) -> bool:
        return bool(
            self.session.scalar(
                select(
                    exists().where(
                        Job.handler == "timeout_execution", Job.dedupe_key == timeout_dedupe_key(self.check_suite.id)
                    )
                )
            )
        )

    def _stage_with_start_in_progress(self, ci_job: CiJob) -> None:
        stage = ci_job.stage
        if stage is None or stage.configuration is None or not stage.configuration.start_in_progress:
            return
        ci_job.in_progress(self.github)
        stage.in_progress(self.github, output={})

    def _create_ci_job(
        self, job: dict, configs: dict[str, StageConfiguration], stages: dict[str, Stage]
    ) -> CiJob | None:
        config = configs.get(job.get("stage") or "")
        if config is None:
            return None
        stage = stages.get(self._stage_name(config))
        self.log.info("create_jobs - %s -> stage %s", job, stage.id if stage else None)
        if not job.get("name") or not job.get("job_ref"):
            self.log.error("Job without name/job_ref ignored: %s", job)  # required fields
            return None
        return CiJob(check_suite_id=self.check_suite.id, name=job.get("name"), job_ref=job.get("job_ref"), stage=stage)

    def _create_check_run_stage(self, stage_config: StageConfiguration, resume: bool = False) -> None:
        self.log.info("create_check_run_stage - %s - %s", stage_config.github_check_run_name, self.name)
        stage = self.session.scalars(
            select(Stage)
            .where(Stage.name == self._stage_name(stage_config), Stage.check_suite_id == self.check_suite.id)
            .order_by(Stage.id)
        ).first()
        if stage is None:
            self._create_stage(stage_config)
            return
        if resume:
            self._complete_stage(stage, stage_config)
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
        stage.enqueue(self.github, output=self._uninitialized_output(stage))
        if stage_config.start_in_progress:
            stage.in_progress(self.github)
        return stage

    def _complete_stage(self, stage: Stage, stage_config: StageConfiguration) -> None:
        """Resume: give a stage stored by a failed run only what it lacks."""
        if stage.check_ref is None:
            stage.enqueue(self.github, output=self._uninitialized_output(stage))
        if stage_config.start_in_progress and stage.state == Status.QUEUED:
            stage.in_progress(self.github)

    def _uninitialized_output(self, stage: Stage) -> dict[str, str]:
        url = self.settings.browse_url(self.check_suite.bamboo_ci_ref)
        return {"title": f"{stage.name} summary", "summary": f"Uninitialized stage\nDetails at [{url}]({url})"}

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
