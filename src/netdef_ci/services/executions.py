#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/executions.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Creation of CI executions: PR events, `ci:rerun` comments and check-suite re-requests.

Ports workers/create_execution_by_{plan,comment,command}.rb and Github::ReRun::Base. These flows start Bamboo plans
(not idempotent), so they run as single-attempt jobs and are serialized per pull request."""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from netdef_ci import container, metrics
from netdef_ci.enums import Status
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.logs import Log
from netdef_ci.models import AuditRetry, CheckSuite, CiJob, Plan, PullRequest, Stage
from netdef_ci.services.action import Action
from netdef_ci.services.common import find_pull_request
from netdef_ci.services.plan_run import PlanRun
from netdef_ci.services.unavailable_jobs import UnavailableJobs
from netdef_ci.services.user_info import sync_user_info

Response = tuple[int, str]


def dig(data: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def payload_pr_id(payload: dict[str, Any]) -> int | None:
    number = dig(payload, "issue", "number")
    if number is not None:
        return int(number)
    pulls = dig(payload, "check_suite", "pull_requests")
    if isinstance(pulls, list) and pulls:
        return pulls[-1].get("number")
    return None


def _last_in_progress_stage(session: Session, check_suite: CheckSuite) -> Stage | None:
    return session.scalars(
        select(Stage).where(Stage.check_suite_id == check_suite.id, Stage.status == Status.IN_PROGRESS).order_by(Stage.id.desc()).limit(1)
    ).first()


def ci_vars(github: Any) -> list[dict[str, str]]:
    return [{"value": github.signature(), "name": "signature_secret"}]


class CreateExecutionByPlan:
    """New execution for a plan after a pull_request event."""

    def __init__(self, session: Session, pull_request_id: int, payload: dict[str, Any], plan_id: int) -> None:
        self.session = session
        self.pull_request = session.get(PullRequest, pull_request_id)
        if self.pull_request is None:
            raise LookupError(f"PullRequest {pull_request_id} not found")
        self.payload = payload
        self.plan = session.get(Plan, plan_id)
        self.status: Response | tuple = ()
        self.has_previous_exec = False
        self.last_check_suite: CheckSuite | None = None
        self.check_suite: CheckSuite | None = None
        self.github: Any = None
        self.log = Log("create_execution_by_plan", self.pull_request.github_pr_id)

    @classmethod
    def run(cls, session: Session, pull_request_id: int, payload: dict[str, Any], plan_id: int) -> Response | tuple:
        plan = session.get(Plan, plan_id)
        if plan is None:
            return 422, "Plan not found"
        instance = cls(session, pull_request_id, payload, plan_id)
        with pull_request_lock(pull_request_id):
            instance.execute()
        instance.log.info("Plan '%s' for Pull Request ID %s finished with status %s", plan.name, pull_request_id, instance.status)
        return instance.status

    def execute(self) -> None:
        plan = self.plan
        assert plan is not None and self.pull_request is not None
        self.log.info("Starting Plan: %s", plan.name)
        self.last_check_suite = self.session.scalars(
            select(CheckSuite)
            .where(CheckSuite.pull_request_id == self.pull_request.id, or_(CheckSuite.plan_id == plan.id, CheckSuite.plan_id.is_(None)))
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()
        payload = self.payload
        author, sha = dig(payload, "pull_request", "user", "login"), dig(payload, "pull_request", "head", "sha")
        if not author or not sha:
            self.status = (422, "Failed to save Check Suite")
            return
        self.check_suite = CheckSuite(
            pull_request_id=self.pull_request.id,
            author=author,
            commit_sha_ref=sha,
            work_branch=dig(payload, "pull_request", "head", "ref"),
            base_sha_ref=dig(payload, "pull_request", "base", "sha"),
            merge_branch=dig(payload, "pull_request", "base", "ref"),
        )
        self.session.add(self.check_suite)
        self.session.commit()
        self.github = container.github(self.check_suite)
        self.check_suite.plan_id = plan.id
        self.session.commit()
        self.log.info("Check Suite created: %s", self.check_suite.id)
        self._stop_previous_execution()
        status = self._start_new_execution(plan)
        if status != 200:
            self.status = (status, "Failed to create CI Plan")
            return
        self.status = self._ci_jobs(plan)

    # ------------------------------------------------------------------
    def _stop_previous_execution(self) -> None:
        last = self.last_check_suite
        if last is None or last.is_finished():
            return
        self.log.info("Stopping previous execution %s", last.id)
        for ci_job in last.running_jobs():
            self.log.warning("Cancelling Job %s", ci_job.id)
            ci_job.cancelled(self.github)
        last.stopped_in_stage_id = getattr(_last_in_progress_stage(self.session, last), "id", None)
        self.session.commit()
        for stage in [s for s in last.stages if s.state in (Status.QUEUED, Status.IN_PROGRESS)]:
            stage.cancelled(self.github)
        self.has_previous_exec = True
        container.bamboo().stop_plan(last.bamboo_ci_ref)

    def _start_new_execution(self, plan: Plan) -> int:
        assert self.check_suite is not None and self.pull_request is not None
        self.check_suite.pull_request_id = self.pull_request.id
        self.session.commit()
        sync_user_info(self.session, dig(self.payload, "pull_request", "user", "id"), check_suite=self.check_suite)
        run = PlanRun(self.check_suite, plan)
        run.ci_variables = ci_vars(self.github)
        return run.start_plan()

    def _ci_jobs(self, plan: Plan) -> Response:
        assert self.check_suite is not None
        container.slack().execution_started_notification(self.check_suite)
        jobs = container.bamboo().running_plan(self.check_suite.bamboo_ci_ref)
        if not jobs:
            return 422, "Failed to fetch RunningPlan"
        Action(self.check_suite, self.github, jobs, plan.name).create_summary()
        if self.has_previous_exec:
            self._stop_execution_message()
        return 200, "Pull Request created"

    def _stop_execution_message(self) -> None:
        assert self.check_suite is not None and self.last_check_suite is not None
        self.check_suite.cancelled_previous_check_suite_id = self.last_check_suite.id
        self.session.commit()
        container.bamboo().comment_cancelled(self.last_check_suite, self.check_suite)


class RerunBase:
    """Shared behaviour of `ci:rerun` flows (Github::ReRun::Base)."""

    def __init__(self, session: Session, payload: dict[str, Any], log: Log) -> None:
        self.session = session
        self.payload = payload
        self.log = log
        self.github: Any = None
        self.last_check_suite: CheckSuite | None = None

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
                CiJob.status == Status.IN_PROGRESS,
            )
            .distinct()
            .order_by(CheckSuite.id)
        )
        return list(self.session.scalars(stmt))

    def stop_previous_execution(self, plan: Plan) -> None:
        suites = self._running_suites(plan)
        if not suites:
            return
        self.log.info("Stopping previous execution")
        self.last_check_suite = None
        for check_suite in suites:
            self._stop_and_update(check_suite)

    def _stop_and_update(self, check_suite: CheckSuite) -> None:
        stage = getattr(_last_in_progress_stage(self.session, check_suite), "id", None)
        if self.last_check_suite is None:
            check_suite.stopped_in_stage_id = stage
        else:
            check_suite.cancelled_previous_check_suite_id = self.last_check_suite.id
            self.last_check_suite.stopped_in_stage_id = stage
        self.session.commit()
        for ci_job in [j for j in check_suite.ci_jobs if j.state != Status.SKIPPED]:
            ci_job.cancelled(self.github)
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
        container.slack().execution_started_notification(check_suite)
        check_suite.cancelled_previous_check_suite_id = self.last_check_suite.id if self.last_check_suite else None
        self.session.commit()
        jobs = container.bamboo().running_plan(check_suite.bamboo_ci_ref)
        Action(check_suite, self.github, jobs, plan.name).create_summary(rerun=True)
        for suite in list(self.session.scalars(select(CheckSuite).where(CheckSuite.commit_sha_ref == check_suite.commit_sha_ref).order_by(CheckSuite.id))):
            UnavailableJobs(suite).update(new_check_suite=check_suite)

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


class CreateExecutionByCommand(RerunBase):
    """Re-run requested through the Checks UI (check_suite `rerequested`)."""

    @classmethod
    def run(cls, session: Session, plan_id: int, check_suite_id: int, payload: dict[str, Any]) -> Response:
        check_suite = session.get(CheckSuite, check_suite_id)
        plan = session.get(Plan, plan_id)
        if check_suite is None or plan is None:
            return 404, "Failed to fetch a check suite"
        instance = cls(session, payload, Log("github_rerun_command"))
        assert check_suite.pull_request is not None
        with pull_request_lock(check_suite.pull_request.id):
            instance.execute(plan, check_suite)
        return 200, "Starting re-run (command)"

    def execute(self, plan: Plan, old_suite: CheckSuite) -> None:
        self.github = container.github(old_suite)
        self.stop_previous_execution(plan)
        check_suite = self.copy_check_suite(old_suite)
        # Same as the Ruby flow: this suite is not linked to `plan` (plan_id stays NULL).
        self.start_new_execution(check_suite, plan)
        self.ci_jobs(check_suite, plan)


class CreateExecutionByComment(RerunBase):
    """`ci:rerun [#sha]` comment."""

    @classmethod
    def run(cls, session: Session, pull_request_id: int, payload: dict[str, Any], plan_id: int) -> Response:
        plan = session.get(Plan, plan_id)
        if plan is None:
            return 422, "Plan not found"
        pull_request = session.get(PullRequest, pull_request_id)
        if pull_request is None:
            raise LookupError(f"PullRequest {pull_request_id} not found")
        instance = cls(session, payload, Log("github_rerun_comment", pull_request.github_pr_id))
        instance.pull_request = pull_request
        with pull_request_lock(pull_request_id):
            return instance.execute(plan)

    pull_request: PullRequest
    old_check_suite: CheckSuite | None = None

    @property
    def action(self) -> str:
        return str(dig(self.payload, "comment", "body") or "")

    @property
    def sha(self) -> str | None:
        if "ci:rerun #" not in self.action.lower():
            return None
        return self.action.lower().split("#")[-1].strip() or None

    def execute(self, plan: Plan) -> Response:
        check_suite = self._check_suite_by_sha_or_comment()
        self.log.debug(">>> Check suite: %s", check_suite)
        if check_suite is None:
            return 404, "Failed to create a check suite"
        check_suite.plan_id = plan.id
        self.session.commit()
        self.stop_previous_execution(plan)
        self.start_new_execution(check_suite, plan)
        self.ci_jobs(check_suite, plan)
        return 201, "Starting re-run (comment)"

    def _fetch_old_check_suite(self, sha: str | None) -> CheckSuite | None:
        if sha is None:
            return None
        stmt = (
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(CheckSuite.commit_sha_ref.ilike(f"{sha}%"), PullRequest.repository == self.repo)
            .order_by(CheckSuite.id.desc())
            .limit(1)
        )
        return self.session.scalars(stmt).first()

    def _check_suite_by_sha_or_comment(self) -> CheckSuite | None:
        self.old_check_suite = self._fetch_old_check_suite(self.sha)
        if self.old_check_suite is None:
            return self._comment_flow()
        self.github = container.github(self.old_check_suite)
        return self.copy_check_suite(self.old_check_suite, self.pull_request)

    def _comment_flow(self) -> CheckSuite | None:
        from netdef_ci.services.commits import PullRequestCommit

        assert self.pr_id is not None and self.repo is not None
        parser = PullRequestCommit(self.session, self.repo, self.pr_id)
        commit = parser.find_by_sha(self.sha)
        if not (commit and re.search(r"ci:rerun\s+#", self.action, re.I)):
            commit = parser.last_commit_in_pr()
        if commit is None:
            return None
        github = container.github(self.pull_request.last_check_suite())
        info = github.pull_request_info(self.pr_id, self.repo)
        check_suite = CheckSuite(
            pull_request_id=self.pull_request.id,
            author=dig(self.payload, "comment", "user", "login"),
            commit_sha_ref=commit["sha"],
            work_branch=dig(info, "head", "ref"),
            base_sha_ref=dig(info, "base", "sha"),
            merge_branch=dig(info, "base", "ref"),
            re_run=True,
        )
        if not check_suite.author:
            return None
        self.session.add(check_suite)
        self.session.commit()
        self.github = container.github(check_suite)
        return check_suite


__all__ = ["CreateExecutionByPlan", "CreateExecutionByComment", "CreateExecutionByCommand", "find_pull_request"]
