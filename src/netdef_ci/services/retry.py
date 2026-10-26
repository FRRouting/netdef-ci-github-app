#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/retry.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Partial retry (`ci:retry` comment / check_run re-request) of a finished check suite
(port of Github::Retry::{Base,Command,Comment} and Github::Build::Retry)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container, metrics
from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.logs import Log
from netdef_ci.models import AuditRetry, CheckSuite, CiJob, PullRequestSubscription, Stage, StageConfiguration
from netdef_ci.services.common import find_pull_request
from netdef_ci.services.executions import dig
from netdef_ci.services.unavailable_jobs import UnavailableJobs
from netdef_ci.services.user_info import sync_user_info

Response = tuple[int, str]


class BuildRetry:
    """Re-queues the stages/jobs that did not pass (Github::Build::Retry)."""

    def __init__(self, session: Session, check_suite: CheckSuite, github: Any, audit_retry: AuditRetry) -> None:
        self.session = session
        self.check_suite = check_suite
        self.github = github
        self.audit_retry = audit_retry
        assert check_suite.pull_request is not None
        self.log = Log("github_build_retry", check_suite.pull_request.github_pr_id)
        self.log.warning(">>>> Retrying check_suite: %s", check_suite.id)

    def enqueued_stages(self) -> None:
        settings = get_settings()
        for config in self.session.scalars(select(StageConfiguration).order_by(StageConfiguration.id)):
            if not config.can_retry:
                continue
            stage = self.session.scalars(
                select(Stage)
                .where(Stage.check_suite_id == self.check_suite.id, Stage.name == config.github_check_run_name)
                .order_by(Stage.id)
                .limit(1)
            ).first()
            if stage is None or stage.state == Status.SUCCESS:
                continue
            url = settings.browse_url(self.check_suite.bamboo_ci_ref)
            stage.enqueue(
                self.github,
                output={"title": f"{stage.name} summary", "summary": f"Uninitialized stage\nDetails at [{url}]({url})"},
            )

    def enqueued_failure_tests(self) -> None:
        for ci_job in [j for j in self.check_suite.ci_jobs if j.state != Status.SUCCESS]:
            if ci_job.stage is None or ci_job.stage.configuration is None or not ci_job.stage.configuration.can_retry:
                continue
            self.log.warning("Enqueue CiJob: %s", ci_job.id)
            ci_job.enqueue(self.github)
            ci_job.retry = (ci_job.retry or 0) + 1
            self.audit_retry.ci_jobs.append(ci_job)
            self.session.commit()


class RetryBase:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        self.payload = payload
        self.stage: Stage | None = None
        self.check_suite: CheckSuite | None = None
        self.comment_id: int | None = None
        self.log = Log("github_retry")

    def start(self) -> Response:
        if not self.payload:
            return 422, "Payload can not be blank"
        self.log.debug("Running stage %s", self.stage.id if self.stage else None)
        if self.stage is None:
            return 404, "Stage not found"
        if self.stage.state in (Status.QUEUED, Status.IN_PROGRESS):
            return 406, "Already enqueued this execution"
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


class RetryCommand(RetryBase):
    """check_run `rerequested` (Re-run button of a single check run)."""

    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        super().__init__(session, payload)
        check_ref = dig(payload, "check_run", "id")
        if check_ref is not None:
            self.stage = session.scalars(
                select(Stage).where(Stage.check_ref == str(check_ref)).order_by(Stage.id.desc()).limit(1)
            ).first()


class RetryComment(RetryBase):
    """`ci:retry` comment."""

    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        super().__init__(session, payload)
        pull_request = find_pull_request(
            session, dig(payload, "issue", "number"), dig(payload, "repository", "full_name")
        )
        if pull_request is not None:
            self.check_suite = pull_request.last_check_suite()
            if self.check_suite is not None:
                failing = self.check_suite.stages_failure()
                self.stage = min(failing, key=lambda s: s.id) if failing else None
        self.comment_id = dig(payload, "comment", "id")

    def start(self) -> Response:
        output = super().start()
        self.log.info("Github::Retry::Comment - response %s", output)
        self._reaction(self.comment_id, up=output[0] not in (404, 406, 422))
        return output


__all__ = ["CiJob", "RetryCommand", "RetryComment"]
