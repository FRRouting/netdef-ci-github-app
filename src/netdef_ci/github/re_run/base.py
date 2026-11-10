#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/re_run/base.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Shared behaviour of the `ci:rerun` flows: stop the running executions of a plan, copy a check suite and start
it again (port of Github::ReRun::Base)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.bamboo_ci.plan_run import PlanRun, ci_vars
from netdef_ci.bamboo_ci.stop_plan import (
    cancel_jobs_without_check_run,
    last_in_progress_stage,
    started_without_checks,
    wait_until_stopped,
)
from netdef_ci.enums import RUNNING_STATUSES, Status
from netdef_ci.github.build.checks_setup import setup_or_defer
from netdef_ci.github.user_info import sync_user_info
from netdef_ci.helpers import metrics
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig, payload_pr_id
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.models import AuditRetry, CheckSuite, CiJob, Plan, PullRequest


class RerunBase:
    """Shared behaviour of `ci:rerun` flows (Github::ReRun::Base)."""

    QUEUE = ""  # per-PR queue of the creation job, reused by its `setup_github_checks` job

    def __init__(self, session: Session, payload: dict[str, Any], log: Log) -> None:
        self.session = session
        self.payload = payload
        self.log = log
        self.github: Any = None
        self.last_check_suite: CheckSuite | None = None
        self.stopped_suites: list[CheckSuite] = []

    @property
    def pr_id(self) -> int | None:
        return payload_pr_id(self.payload)

    @property
    def repo(self) -> str | None:
        return dig(self.payload, "repository", "full_name")

    def _running_suites(self, plan: Plan) -> list[CheckSuite]:
        stmt = (
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .join(Plan, Plan.pull_request_id == PullRequest.id)
            .join(CiJob, CiJob.check_suite_id == CheckSuite.id)
            .where(
                Plan.id == plan.id,
                PullRequest.github_pr_id == self.pr_id,
                PullRequest.repository == self.repo,
                CiJob.status.in_(list(RUNNING_STATUSES)),  # a suite whose jobs are all queued is running too
            )
            .distinct()
            .order_by(CheckSuite.id)
        )
        suites = list(self.session.scalars(stmt))
        untracked = self._started_without_checks(plan)
        if untracked is not None and untracked not in suites:
            suites.append(untracked)
        return suites

    def _started_without_checks(self, plan: Plan) -> CheckSuite | None:
        """The newest execution of the plan, when Bamboo started it but its GitHub setup never created a stage or CI
        job (the query above only sees suites with running CI jobs)."""
        newest = self.session.scalars(
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(
                PullRequest.github_pr_id == self.pr_id,
                PullRequest.repository == self.repo,
                or_(CheckSuite.plan_id == plan.id, CheckSuite.plan_id.is_(None)),
                CheckSuite.bamboo_ci_ref.is_not(None),
            )
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()
        if newest is None or not started_without_checks(self.session, newest):
            return None
        return newest

    def stop_previous_execution(self, plan: Plan) -> None:
        suites = self._running_suites(plan)
        if not suites:
            return
        self.log.info("Stopping previous execution")
        self.last_check_suite = None
        self.stopped_suites = suites
        for check_suite in suites:
            self._stop_and_update(check_suite)
        wait_until_stopped([suite.bamboo_ci_ref for suite in suites], self.log)

    def _stop_and_update(self, check_suite: CheckSuite) -> None:
        """Database and Bamboo only; the open check runs of `check_suite` are cancelled by ChecksSetup after the new
        plan started, so a GitHub error cannot keep the old build running or the new one from starting."""
        stage = getattr(last_in_progress_stage(self.session, check_suite), "id", None)
        if self.last_check_suite is None:
            check_suite.stopped_in_stage_id = stage
        else:
            check_suite.cancelled_previous_check_suite_id = self.last_check_suite.id
            self.last_check_suite.stopped_in_stage_id = stage
        cancel_jobs_without_check_run([j for j in check_suite.ci_jobs if j.state != Status.SKIPPED], self.github)
        self.session.commit()
        self.last_check_suite = check_suite
        container.bamboo().stop_plan(check_suite.bamboo_ci_ref)

    def start_new_execution(self, check_suite: CheckSuite, plan: Plan) -> int:
        metrics.CI_JOB_RETRIES.labels(reason="full").inc()
        run = PlanRun(check_suite, plan)
        run.ci_variables = ci_vars(self.github)
        status = run.start_plan()
        if status != 200:
            self.log.error("Bamboo plan could not be started for check suite %s (status %s)", check_suite.id, status)
        sender = self.payload.get("sender") or {}
        audit = AuditRetry(
            check_suite_id=check_suite.id,
            github_username=sender.get("login"),
            github_id=None if sender.get("id") is None else str(sender.get("id")),
            github_type=sender.get("type"),
            retry_type="full",
        )
        self.session.add(audit)
        self.session.commit()
        sync_user_info(self.session, sender.get("id"), check_suite=check_suite, audit_retry=audit)
        return status

    def ci_jobs(self, check_suite: CheckSuite, plan: Plan) -> None:
        """GitHub phase (ChecksSetup): closes the stopped executions' check runs, comments on their Bamboo builds,
        creates the new stages and check runs and skips jobs removed from the plan; deferred when GitHub fails."""
        pull_request = check_suite.pull_request
        assert pull_request is not None
        setup_or_defer(
            self.session,
            check_suite,
            plan,
            [suite.id for suite in self.stopped_suites],
            rerun=True,
            queue=jobs_queue.execution_queue(self.QUEUE, pull_request.github_pr_id),
            log=self.log,
        )

    def copy_check_suite(self, source: CheckSuite, pull_request: PullRequest | None = None) -> CheckSuite:
        suite = CheckSuite(
            pull_request_id=(pull_request or source.pull_request).id,  # type: ignore[union-attr]
            author=source.author,
            commit_sha_ref=source.commit_sha_ref,
            work_branch=source.work_branch,
            base_sha_ref=source.base_sha_ref,
            merge_branch=source.merge_branch,
            re_run=True,
        )
        self.session.add(suite)
        self.session.commit()
        return suite


def plans_for(session: Session, pull_request: PullRequest, repo: str | None) -> list[Plan]:
    return list(pull_request.plans) or list(
        session.scalars(select(Plan).where(Plan.github_repo_name == repo).order_by(Plan.id))
    )
