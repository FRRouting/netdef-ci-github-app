#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/executions.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Creation of CI executions: PR events, `ci:rerun` comments and check-suite re-requests.

Ports workers/create_execution_by_{plan,comment,command}.rb and Github::ReRun::Base. These flows start Bamboo plans
(not idempotent), so they run as single-attempt jobs and are serialized per pull request. Each one runs in phases so
that a GitHub failure never leaves a started build untracked or blocks the next one: (1) authenticate to GitHub before
anything is written, (2) stop the previous execution in Bamboo, (3) start the new plan, (4) the GitHub-only setup in
`services/checks_setup.py`, which is deferred to the retryable `setup_github_checks` job when it fails."""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import exists, or_, select
from sqlalchemy.orm import Session

from netdef_ci import container, metrics
from netdef_ci.clients.github import GithubAuthError
from netdef_ci.config import get_settings
from netdef_ci.enums import RUNNING_STATUSES, Status
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.logs import Log
from netdef_ci.models import AuditRetry, CheckSuite, CiJob, Plan, PullRequest, Stage
from netdef_ci.services.checks_setup import setup_or_defer
from netdef_ci.services.common import find_pull_request, wait_until_stopped
from netdef_ci.services.plan_run import PlanRun
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
        select(Stage)
        .where(Stage.check_suite_id == check_suite.id, Stage.status == Status.IN_PROGRESS)
        .order_by(Stage.id.desc())
        .limit(1)
    ).first()


def ci_vars(github: Any) -> list[dict[str, str]]:
    return [{"value": github.signature(), "name": "signature_secret"}]


def _started_without_checks(session: Session, check_suite: CheckSuite) -> bool:
    """Started in Bamboo, but its GitHub setup died before creating any stage or CI job (PR 8118). Its stages cannot
    tell whether it still runs, so Bamboo is asked."""
    if not check_suite.bamboo_ci_ref:
        return False
    has_rows = session.scalar(
        select(
            or_(
                exists().where(Stage.check_suite_id == check_suite.id),
                exists().where(CiJob.check_suite_id == check_suite.id),
            )
        )
    )
    return not has_rows and not container.bamboo().is_stopped(check_suite.bamboo_ci_ref)


def _cancel_jobs_without_check_run(jobs: list[CiJob], github: Any) -> None:
    """Database-only cancellation before the Bamboo stop: late callbacks of the stopped build then find the jobs
    closed. Jobs with a check run (never created by this app) are cancelled on GitHub by ChecksSetup."""
    for ci_job in jobs:
        if ci_job.check_ref is None:
            ci_job.cancelled(github, commit=False)


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
    def run(
        cls,
        session: Session,
        pull_request_id: int,
        payload: dict[str, Any],
        plan_id: int,
        attempt: int = 1,
        latest_check_suite_id: int | None = None,
    ) -> Response | tuple:
        """`attempt` > 1 is a retry scheduled after GitHub authentication failed (nothing was written then);
        `latest_check_suite_id` is the newest suite of the plan at that time: a newer one means a later push already
        started, and the retry must not stop it."""
        plan = session.get(Plan, plan_id)
        if plan is None:
            return 422, "Plan not found"
        instance = cls(session, pull_request_id, payload, plan_id)
        with pull_request_lock(pull_request_id):
            if attempt > 1 and instance.superseded(latest_check_suite_id):
                instance.log.info("Retry %s of plan '%s' skipped: a newer execution exists", attempt, plan.name)
                return 409, "Superseded by a newer execution"
            instance.execute(attempt)
        instance.log.info(
            "Plan '%s' for Pull Request ID %s finished with status %s", plan.name, pull_request_id, instance.status
        )
        return instance.status

    def superseded(self, latest_check_suite_id: int | None) -> bool:
        assert self.plan is not None and self.pull_request is not None
        newest = self._newest_suite_id()
        return newest is not None and newest > (latest_check_suite_id or 0)

    def _newest_suite_id(self) -> int | None:
        assert self.plan is not None and self.pull_request is not None
        return self.session.scalars(
            select(CheckSuite.id)
            .where(CheckSuite.pull_request_id == self.pull_request.id, CheckSuite.plan_id == self.plan.id)
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()

    def execute(self, attempt: int = 1) -> None:
        plan = self.plan
        assert plan is not None and self.pull_request is not None
        self.log.info("Starting Plan: %s", plan.name)
        # Only suites that reached Bamboo: one whose creation failed before the start has nothing to stop.
        self.last_check_suite = self.session.scalars(
            select(CheckSuite)
            .where(
                CheckSuite.pull_request_id == self.pull_request.id,
                or_(CheckSuite.plan_id == plan.id, CheckSuite.plan_id.is_(None)),
                CheckSuite.bamboo_ci_ref.is_not(None),
            )
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()
        payload = self.payload
        author, sha = dig(payload, "pull_request", "user", "login"), dig(payload, "pull_request", "head", "sha")
        if not author or not sha:
            self.status = (422, "Failed to save Check Suite")
            return
        self.check_suite = CheckSuite(
            pull_request=self.pull_request,
            plan_id=plan.id,
            author=author,
            commit_sha_ref=sha,
            work_branch=dig(payload, "pull_request", "head", "ref"),
            base_sha_ref=dig(payload, "pull_request", "base", "sha"),
            merge_branch=dig(payload, "pull_request", "base", "ref"),
        )
        self.session.add(self.check_suite)
        self.github = container.github(self.check_suite)
        try:
            self.github.authenticate()  # before the first commit: a failure leaves nothing behind
        except GithubAuthError as error:
            self.session.rollback()
            self.check_suite = None
            self._retry_authentication(attempt, error)
            return
        self.session.commit()
        self.log.info("Check Suite created: %s", self.check_suite.id)
        self._stop_previous_execution()
        status = self._start_new_execution(plan)
        if status != 200:
            self.status = (status, "Failed to create CI Plan")
            return
        previous = [self.last_check_suite.id] if self.has_previous_exec and self.last_check_suite else []
        self.status = setup_or_defer(
            self.session,
            self.check_suite,
            plan,
            previous,
            rerun=False,
            queue=jobs_queue.execution_queue("create_execution_by_plan", self.pull_request.github_pr_id),
            log=self.log,
        )

    # ------------------------------------------------------------------
    def _retry_authentication(self, attempt: int, error: Exception) -> None:
        """Nothing was written and nothing was started, so the whole creation may run again (bounded by
        JOB_MAX_ATTEMPTS, with the job queue back-off)."""
        assert self.plan is not None and self.pull_request is not None
        max_attempts = get_settings().job_max_attempts
        if attempt >= max_attempts:
            self.log.error(
                "GitHub authentication failed for plan '%s' (attempt %s of %s): %s; no execution was created",
                self.plan.name,
                attempt,
                max_attempts,
                error,
            )
            self.status = (503, "GitHub authentication failed")
            return
        delay = 5 + attempt**4
        self.log.error(
            "GitHub authentication failed for plan '%s' (attempt %s of %s): %s; nothing was saved, retrying in %ss",
            self.plan.name,
            attempt,
            max_attempts,
            error,
            delay,
        )
        jobs_queue.enqueue(
            self.session,
            "create_execution_by_plan",
            [self.pull_request.id, self.payload, self.plan.id, attempt + 1, self._newest_suite_id()],
            queue=jobs_queue.execution_queue("create_execution_by_plan", self.pull_request.github_pr_id),
            delay_seconds=delay,
            max_attempts=1,  # starts a Bamboo plan: never repeated automatically
        )
        self.status = (503, "GitHub authentication failed; retry scheduled")

    def _stop_previous_execution(self) -> None:
        """Bamboo first: GitHub is only called afterwards (ChecksSetup), so a GitHub error can no longer leave the old
        build running and the new one not started."""
        last = self.last_check_suite
        if last is None or (last.is_finished() and not _started_without_checks(self.session, last)):
            return
        self.log.info("Stopping previous execution %s (%s)", last.id, last.bamboo_ci_ref)
        _cancel_jobs_without_check_run(last.running_jobs(), self.github)
        last.stopped_in_stage_id = getattr(_last_in_progress_stage(self.session, last), "id", None)
        self.session.commit()
        self.has_previous_exec = True
        container.bamboo().stop_plan(last.bamboo_ci_ref)
        # The new execution only starts once Bamboo confirms the stop (or the wait limit is reached).
        wait_until_stopped([last.bamboo_ci_ref], self.log)

    def _start_new_execution(self, plan: Plan) -> int:
        assert self.check_suite is not None
        sync_user_info(self.session, dig(self.payload, "pull_request", "user", "id"), check_suite=self.check_suite)
        run = PlanRun(self.check_suite, plan)
        run.ci_variables = ci_vars(self.github)
        return run.start_plan()


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
        if newest is None or not _started_without_checks(self.session, newest):
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
        stage = getattr(_last_in_progress_stage(self.session, check_suite), "id", None)
        if self.last_check_suite is None:
            check_suite.stopped_in_stage_id = stage
        else:
            check_suite.cancelled_previous_check_suite_id = self.last_check_suite.id
            self.last_check_suite.stopped_in_stage_id = stage
        _cancel_jobs_without_check_run([j for j in check_suite.ci_jobs if j.state != Status.SKIPPED], self.github)
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


class CreateExecutionByCommand(RerunBase):
    """Re-run requested through the Checks UI (check_suite `rerequested`)."""

    QUEUE = "create_execution_by_command"

    @classmethod
    def run(cls, session: Session, plan_id: int, check_suite_id: int, payload: dict[str, Any]) -> Response:
        check_suite = session.get(CheckSuite, check_suite_id)
        plan = session.get(Plan, plan_id)
        if check_suite is None or plan is None:
            return 404, "Failed to fetch a check suite"
        instance = cls(session, payload, Log("github_rerun_command"))
        assert check_suite.pull_request is not None
        with pull_request_lock(check_suite.pull_request.id):
            failed = instance.execute(plan, check_suite)
        return failed or (200, "Starting re-run (command)")

    def execute(self, plan: Plan, old_suite: CheckSuite) -> Response | None:
        self.github = container.github(old_suite)
        self.stop_previous_execution(plan)
        check_suite = self.copy_check_suite(old_suite)
        # This suite is not linked to `plan` (plan_id stays NULL).
        status = self.start_new_execution(check_suite, plan)
        if status != 200:  # no Bamboo execution exists: do not create stages/check runs for it
            return (status, "Failed to create CI Plan")
        self.ci_jobs(check_suite, plan)
        return None


class CreateExecutionByComment(RerunBase):
    """`ci:rerun [#sha]` comment."""

    QUEUE = "create_execution_by_comment"

    @classmethod
    def run(
        cls,
        session: Session,
        pull_request_id: int,
        payload: dict[str, Any],
        plan_id: int,
        rocket_reaction_id: int | None = None,
    ) -> Response:
        pull_request = session.get(PullRequest, pull_request_id)
        if pull_request is None:
            raise LookupError(f"PullRequest {pull_request_id} not found")
        instance = cls(session, payload, Log("github_rerun_comment", pull_request.github_pr_id))
        instance.pull_request = pull_request
        instance.rocket_reaction_id = rocket_reaction_id
        plan = session.get(Plan, plan_id)
        if plan is None:
            instance.finish_reaction(started=False)
            return 422, "Plan not found"
        try:
            with pull_request_lock(pull_request_id):
                return instance.execute(plan)
        finally:
            instance.finish_reaction(started=False)  # no-op when the outcome was already reported

    pull_request: PullRequest
    old_check_suite: CheckSuite | None = None
    rocket_reaction_id: int | None = None
    reaction_finished = False

    def finish_reaction(self, *, started: bool) -> None:
        """Replace the rocket added on receipt by +1 (Bamboo plan submitted) or -1 (not started). Reaction errors are
        only logged: they never change the outcome of the execution."""
        if self.reaction_finished:
            return
        self.reaction_finished = True
        comment_id = dig(self.payload, "comment", "id")
        if comment_id is None or self.repo is None:
            return
        github = container.github(self.pull_request.last_check_suite())
        if self.rocket_reaction_id is not None:
            try:
                github.delete_comment_reaction(self.repo, comment_id, self.rocket_reaction_id)
            except Exception as error:  # e.g. already removed by the job of another plan
                self.log.info("Could not remove rocket reaction from comment %s: %s", comment_id, error)
        try:
            (github.comment_reaction_thumb_up if started else github.comment_reaction_thumb_down)(self.repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)

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
        status = self.start_new_execution(check_suite, plan)
        self.finish_reaction(started=status == 200)
        if status != 200:  # no Bamboo execution exists: do not create stages/check runs for it
            return (status, "Failed to create CI Plan")
        self.ci_jobs(check_suite, plan)
        return 201, "Starting re-run (comment)"

    def _fetch_old_check_suite(self, sha: str | None) -> CheckSuite | None:
        if sha is None:
            return None
        stmt = (
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(CheckSuite.commit_sha_ref.startswith(sha, autoescape=True), PullRequest.repository == self.repo)
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
        commit = PullRequestCommit(self.session, self.repo, self.pr_id).find_by_sha(self.sha)
        github = container.github(self.pull_request.last_check_suite())
        info = github.pull_request_info(self.pr_id, self.repo)
        # Without an explicit sha: the head of the PR is its last commit (no paging through the commit list).
        explicit = commit and re.search(r"ci:rerun\s+#", self.action, re.I)
        sha = commit["sha"] if commit and explicit else dig(info, "head", "sha")
        if not sha:
            return None
        check_suite = CheckSuite(
            pull_request_id=self.pull_request.id,
            author=dig(self.payload, "comment", "user", "login"),
            commit_sha_ref=sha,
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


__all__ = ["CreateExecutionByCommand", "CreateExecutionByComment", "CreateExecutionByPlan", "find_pull_request"]
