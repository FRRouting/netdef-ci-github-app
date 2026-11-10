#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/retry/base.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Partial retry of a finished check suite, shared by the `ci:retry` comment and the check run re-run
(port of Github::Retry::Base)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.enums import Status
from netdef_ci.github.build.retry import BuildRetry
from netdef_ci.github.build.unavailable_jobs import UnavailableJobs
from netdef_ci.github.duplicate_request_guard import CommandGuard
from netdef_ci.github.user_info import sync_user_info
from netdef_ci.helpers import metrics
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.models import AuditRetry, CheckSuite, PullRequestSubscription, Stage

Response = tuple[int, str]


REFUSED = (404, 406, 409, 422)  # answers that mean "nothing was retried" (the comment gets :-1:)


class RetryBase:
    KIND = ""  # `retry_execution` job argument that rebuilds this class (see `run`)

    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        self.payload = payload
        self.stage: Stage | None = None
        self.check_suite: CheckSuite | None = None
        self.comment_id: int | None = None
        self.log = Log("github_retry")

    def _refusal(self) -> Response | None:
        if not self.payload:
            return 422, "Payload can not be blank"
        self.log.debug("Running stage %s", self.stage.id if self.stage else None)
        if self.stage is None:
            return 404, "Stage not found"
        if self.stage.state in (Status.QUEUED, Status.IN_PROGRESS):
            return 406, "Already enqueued this execution"
        return None

    def schedule(self) -> Response:
        """Webhook side: answer the requests that cannot be retried right away and leave the retry (Bamboo stop and
        restart, check runs, Slack) to a `retry_execution` job. Admitted by `CommandGuard`: one ci:retry/ci:rerun at
        a time per pull request, none again within CI_COMMAND_COOLDOWN_SECONDS."""
        refusal = self._refusal()
        if refusal is not None:
            return refusal
        assert self.stage is not None
        suite = self.stage.check_suite
        if suite is None or suite.pull_request is None:
            return 404, "Stage not found"
        guard = CommandGuard(self.session, suite.pull_request.id)
        with guard.admission() as refused:
            if refused is not None:
                return refused
            guard.enqueue(
                "retry_execution",
                [self.KIND, self.payload],
                queue=jobs_queue.execution_queue("retry_execution", suite.pull_request.github_pr_id),
            )
        return 200, "Retry scheduled"

    def start(self) -> Response:
        refusal = self._refusal()
        if refusal is not None:
            return refusal
        assert self.stage is not None
        self.check_suite = self.stage.check_suite
        assert self.check_suite is not None
        if self.check_suite.is_in_progress():
            return self._enqueued()
        return self._normal_flow()

    # ------------------------------------------------------------------
    def _reaction(self, comment_id: int | None, *, up: bool) -> None:
        if comment_id is None or self.check_suite is None or self.check_suite.pull_request is None:
            return
        try:
            github = container.github(self.check_suite)
            repo = self.check_suite.pull_request.repository
            (github.comment_reaction_thumb_up if up else github.comment_reaction_thumb_down)(repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)

    def _normal_flow(self) -> Response:
        check_suite = self.check_suite
        assert check_suite is not None
        check_suite.retry = (check_suite.retry or 0) + 1
        self.session.commit()
        metrics.CI_JOB_RETRIES.labels(reason="partial").inc()
        self._create_ci_jobs(check_suite)
        container.bamboo().restart(check_suite.bamboo_ci_ref)
        UnavailableJobs(check_suite).update()
        container.slack().execution_started_notification(check_suite)
        if self.comment_id:
            self._reaction(self.comment_id, up=True)
        return 200, "Retrying failure jobs"

    def _create_ci_jobs(self, check_suite: CheckSuite) -> None:
        github = container.github(check_suite)
        sender = self.payload.get("sender") or {}
        audit = AuditRetry(
            check_suite_id=check_suite.id,
            github_username=sender.get("login"),
            github_id=None if sender.get("id") is None else str(sender.get("id")),
            github_type=sender.get("type"),
            retry_type="partial",
        )
        self.session.add(audit)
        self.session.commit()
        sync_user_info(self.session, sender.get("id"), check_suite=check_suite, audit_retry=audit)
        build_retry = BuildRetry(self.session, check_suite, github, audit)
        build_retry.enqueued_stages()
        build_retry.enqueued_failure_tests()
        container.bamboo().stop_plan(check_suite.bamboo_ci_ref)

    def _enqueued(self) -> Response:
        assert self.stage is not None and self.stage.check_suite is not None
        github = container.github(self.stage.check_suite)
        previous = github.get_check_run(self.stage.check_ref) if self.stage.check_ref else {}
        reason = self._slack_notification()
        output = {
            "title": str(dig(previous, "output", "title") or ""),
            "summary": str(dig(previous, "output", "summary") or ""),
        }
        self.stage.enqueue(github)
        self.stage.failure(github, output=output)
        return 406, reason or ""

    def _slack_notification(self) -> str | None:
        assert (
            self.stage is not None
            and self.stage.check_suite is not None
            and self.stage.check_suite.pull_request is not None
        )
        slack = container.slack()
        reason = slack.invalid_rerun_group(self.stage)
        self.log.warning(">>> stage %s %s", self.stage.id, reason)
        pull_request = self.stage.check_suite.pull_request
        stmt = select(PullRequestSubscription).where(
            PullRequestSubscription.target.in_([str(pull_request.github_pr_id), pull_request.author]),
            PullRequestSubscription.notification.in_(["all", "errors"]),
        )
        unique: dict[str, PullRequestSubscription] = {}
        for subscription in self.session.scalars(stmt.order_by(PullRequestSubscription.id)):
            unique.setdefault(subscription.slack_user_id, subscription)
        for subscription in unique.values():
            slack.invalid_rerun_dm(self.stage, subscription)
        return reason
