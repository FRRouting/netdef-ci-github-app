#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/create_execution_by_plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""New execution for a plan after a pull_request event (port of workers/create_execution_by_plan.rb).

It starts a Bamboo plan (not idempotent), so it runs as a single-attempt job serialized per pull request, in phases
so that a GitHub failure never leaves a started build untracked: (1) authenticate to GitHub before anything is
written, (2) stop the previous execution in Bamboo, (3) start the new plan, (4) the GitHub-only setup in
`github/build/checks_setup.py`, deferred to the retryable `setup_github_checks` job (registered here, like Ruby's
`CreateExecutionByPlan.setup_github_checks`) when it fails."""

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
from netdef_ci.clients.github import GithubAuthError
from netdef_ci.github.build.checks_setup import ChecksSetup, setup_or_defer
from netdef_ci.github.user_info import sync_user_info
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.db import session_scope
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CheckSuite, Plan, PullRequest

Response = tuple[int, str]


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
        if last is None or (last.is_finished() and not started_without_checks(self.session, last)):
            return
        self.log.info("Stopping previous execution %s (%s)", last.id, last.bamboo_ci_ref)
        cancel_jobs_without_check_run(last.running_jobs(), self.github)
        last.stopped_in_stage_id = getattr(last_in_progress_stage(self.session, last), "id", None)
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


@job_handler("create_execution_by_plan")
def create_execution_by_plan_job(
    pull_request_id: int,
    payload: dict[str, Any],
    plan_id: int,
    attempt: int = 1,
    latest_check_suite_id: int | None = None,
) -> None:
    with session_scope() as session:
        CreateExecutionByPlan.run(session, pull_request_id, payload, plan_id, attempt, latest_check_suite_id)


@job_handler("setup_github_checks")
def setup_github_checks_job(
    check_suite_id: int, plan_id: int, previous_check_suite_ids: list[int], rerun: bool
) -> None:
    """GitHub-only part of an execution whose Bamboo plan already started; scheduled by every creation flow."""
    with session_scope() as session:
        ChecksSetup.run(session, check_suite_id, plan_id, previous_check_suite_ids, rerun)
