#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/build/checks_setup.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""GitHub side of an execution that Bamboo already started: closes the check runs of the executions it stopped,
creates its stages, CI jobs and check runs and leaves the "cancelled" note on the stopped Bamboo builds.

It never creates a CheckSuite and never starts or stops a Bamboo plan, so, unlike `create_execution_by_*`, it can be
repeated: when it fails in-line the `setup_github_checks` job runs it again with the normal retry count."""

from __future__ import annotations

from collections.abc import Sequence

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.bamboo_ci.running_plan import wait_for_running_jobs
from netdef_ci.enums import RUNNING_STATUSES
from netdef_ci.github.build.action import Action
from netdef_ci.github.build.unavailable_jobs import UnavailableJobs
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.models import CheckSuite, Plan

Response = tuple[int, str]

# First deferred attempt (later ones use the job queue back-off, 5 + attempts**4 s). Short on purpose, as in the Ruby
# application: until the resume creates the CI jobs, Bamboo status callbacks find no job and are dropped (404).
SETUP_RETRY_DELAY_SECONDS = 10


class ChecksSetup:
    """`first_run` is the in-line run of the creation job; only it sends the Slack "execution started" notice."""

    def __init__(
        self,
        session: Session,
        check_suite: CheckSuite,
        plan: Plan,
        previous_check_suite_ids: Sequence[int] = (),
        *,
        rerun: bool = False,
        first_run: bool = True,
    ) -> None:
        assert check_suite.pull_request is not None
        self.session = session
        self.check_suite = check_suite
        self.plan = plan
        self.previous_check_suite_ids = list(previous_check_suite_ids)
        self.rerun = rerun
        self.first_run = first_run
        self.log = Log("github_checks_setup", check_suite.pull_request.github_pr_id)

    @classmethod
    def run(
        cls,
        session: Session,
        check_suite_id: int,
        plan_id: int,
        previous_check_suite_ids: Sequence[int],
        rerun: bool,
    ) -> Response:
        """`setup_github_checks` job: resume the setup of a suite whose in-line run failed. Rows are read again inside
        the pull request lock, the one held by the creation flows."""
        log = Log("github_checks_setup")
        suite = session.get(CheckSuite, check_suite_id)
        plan = session.get(Plan, plan_id)
        if suite is None or suite.pull_request is None or plan is None:
            log.warning("Check Suite %s or plan %s no longer exists; nothing to set up", check_suite_id, plan_id)
            return 404, "Check Suite not found"
        with pull_request_lock(suite.pull_request.id):
            session.expire_all()
            instance = cls(session, suite, plan, previous_check_suite_ids, rerun=rerun, first_run=False)
            if instance.superseded():
                # The newer execution stopped this one and cancels its check runs, but it does not know about the
                # executions this one had stopped: close those, so none is left open on GitHub.
                instance.log.info(
                    "Check Suite %s (%s) was superseded; only closing the executions it stopped",
                    suite.id,
                    suite.bamboo_ci_ref,
                )
                instance.cancel_previous_executions()
                return 200, "Superseded"
            return instance.setup()

    def superseded(self) -> bool:
        """A newer suite of the same pull request and plan was started in Bamboo."""
        newer = self.session.scalars(
            select(CheckSuite.id)
            .where(
                CheckSuite.pull_request_id == self.check_suite.pull_request_id,
                CheckSuite.id > self.check_suite.id,
                CheckSuite.bamboo_ci_ref.is_not(None),
                or_(CheckSuite.plan_id == self.plan.id, CheckSuite.plan_id.is_(None)),
            )
            .limit(1)
        ).first()
        return newer is not None

    def setup(self) -> Response:
        if self.first_run:
            self._notify_started()
        self.cancel_previous_executions()
        self._comment_cancelled()
        jobs = wait_for_running_jobs(self.check_suite.bamboo_ci_ref)
        if not jobs:  # without jobs the stages would stay at "0/0" forever
            self.log.error(
                "No jobs were listed for %s; stages and check runs were not created", self.check_suite.bamboo_ci_ref
            )
            return 422, "Failed to fetch RunningPlan"
        github = container.github(self.check_suite)
        Action(self.check_suite, github, jobs, self.plan.name).create_summary(
            rerun=self.rerun, resume=not self.first_run
        )
        if self.rerun:
            self._skip_unavailable_jobs()
        return 200, "Pull Request created"

    def cancel_previous_executions(self) -> None:
        """Close the check runs of the stopped executions. Only stages and jobs still queued or in progress are touched,
        so a repeated run changes nothing. Jobs without a check run were already cancelled before the Bamboo stop."""
        for suite_id in self.previous_check_suite_ids:
            previous = self.session.get(CheckSuite, suite_id)
            if previous is None:
                continue
            github = container.github(previous)
            for ci_job in previous.running_jobs():
                if ci_job.check_ref is not None:
                    ci_job.cancelled(github)
            # A rerun reuses the commit, so a stage left open and finished later by a late Bamboo callback would
            # create a newer check run with the same name and hide the queued one of the new execution.
            for stage in [s for s in previous.stages if s.state in RUNNING_STATUSES]:
                stage.cancelled(github)

    # ------------------------------------------------------------------
    def _notify_started(self) -> None:
        try:
            container.slack().execution_started_notification(self.check_suite)
        except Exception as error:  # best effort: never reschedules the setup
            self.log.warning(
                "Execution started notification failed for Check Suite %s: %s: %s",
                self.check_suite.id,
                type(error).__name__,
                error,
            )

    def _comment_cancelled(self) -> None:
        """Note on each stopped Bamboo build pointing to the execution that replaced it; sent once, guarded by
        `cancelled_previous_check_suite_id` (stored before the comment, so a repeated run never sends it again)."""
        if not self.previous_check_suite_ids or self.check_suite.cancelled_previous_check_suite_id is not None:
            return
        previous = [s for i in self.previous_check_suite_ids if (s := self.session.get(CheckSuite, i)) is not None]
        if not previous:
            return
        self.check_suite.cancelled_previous_check_suite_id = previous[-1].id
        self.session.commit()
        for stopped in previous:
            container.bamboo().comment_cancelled(stopped, self.check_suite)

    def _skip_unavailable_jobs(self) -> None:
        running_plans: dict[str | None, list[str | None]] = {}
        for suite in list(
            self.session.scalars(
                select(CheckSuite)
                .where(CheckSuite.commit_sha_ref == self.check_suite.commit_sha_ref)
                .order_by(CheckSuite.id)
            )
        ):
            UnavailableJobs(suite).update(new_check_suite=self.check_suite, running_plans=running_plans)


def setup_or_defer(
    session: Session,
    check_suite: CheckSuite,
    plan: Plan,
    previous_check_suite_ids: Sequence[int],
    *,
    rerun: bool,
    queue: str,
    log: Log,
) -> Response:
    """Run the GitHub setup in-line; on any error schedule `setup_github_checks` on `queue` (the creation flow's own
    per-PR queue) instead of failing the creation job, which must never run again once Bamboo started the plan."""
    suite_id, plan_id, bamboo_ci_ref = check_suite.id, plan.id, check_suite.bamboo_ci_ref
    previous = list(previous_check_suite_ids)
    try:
        return ChecksSetup(session, check_suite, plan, previous, rerun=rerun).setup()
    except Exception as error:
        session.rollback()
        log.error(
            "GitHub setup of Check Suite %s (%s) failed: %s: %s; scheduling setup_github_checks",
            suite_id,
            bamboo_ci_ref,
            type(error).__name__,
            error,
        )
        jobs_queue.enqueue(
            session,
            "setup_github_checks",
            [suite_id, plan_id, previous, rerun],
            queue=queue,
            delay_seconds=SETUP_RETRY_DELAY_SECONDS,
        )
        return 202, "GitHub checks setup scheduled"
