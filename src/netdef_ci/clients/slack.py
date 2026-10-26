#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/slack.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack bot notifications (port of lib/slack_bot/slack_bot.rb). Failures never propagate to the CI flow."""

from __future__ import annotations

import json
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.orm import object_session

from netdef_ci import metrics
from netdef_ci.config import Settings
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, PullRequest, PullRequestSubscription, Stage


class SlackBot:
    def __init__(self, settings: Settings, *, transport: httpx.BaseTransport | None = None) -> None:
        self.settings = settings
        self.log = Log("slack_bot")
        credentials = settings.slack_credentials()
        self._auth = (credentials.username, credentials.password) if credentials else None
        self._client = httpx.Client(
            verify=settings.slack_bot_verify_tls,
            timeout=settings.http_timeout_seconds,
            transport=transport,
            auth=self._auth,
        )

    # ------------------------------------------------------------------ transport
    def _base(self) -> str | None:
        return self.settings.slack_bot_url.rstrip("/") if self.settings.slack_bot_url else None

    def _post(self, path: str, body: str) -> httpx.Response | None:
        base = self._base()
        if base is None:
            self.log.warning("SLACK_BOT_URL is not configured; notification dropped")
            return None
        try:
            # The Slack bot contract: JSON/plain body sent with `Content-Type: application/xml` (required by the Slack bot).
            return self._client.post(
                f"{base}{path}",
                content=body.encode(),
                headers={"Content-Type": "application/xml", "Accept": "application/json"},
            )
        except Exception as error:
            self.log.error("Slack POST failed (%s: %s) for %s", type(error).__name__, error, path)
            return None

    def find_user_id_by_name(self, username: str) -> str | None:
        base = self._base()
        if base is None:
            return None
        try:
            return self._client.get(f"{base}/github/translate/{username}").text
        except Exception as error:
            self.log.error("Slack GET failed (%s: %s)", type(error).__name__, error)
            return None

    # ------------------------------------------------------------------ helpers
    @staticmethod
    def _current_execution(check_suite: CheckSuite) -> bool:
        pull_request = check_suite.pull_request
        assert pull_request is not None
        last = pull_request.last_check_suite()
        return check_suite.id >= (last.id if last is not None else 0)

    @staticmethod
    def _subscriptions(
        pull_request: PullRequest, notifications: tuple[str, ...] | None = None
    ) -> list[PullRequestSubscription]:
        session = object_session(pull_request)
        assert session is not None
        stmt = select(PullRequestSubscription).where(
            PullRequestSubscription.target.in_([str(pull_request.github_pr_id), pull_request.author])
        )
        if notifications:
            stmt = stmt.where(PullRequestSubscription.notification.in_(list(notifications)))
        unique: dict[str, PullRequestSubscription] = {}
        for subscription in session.scalars(stmt.order_by(PullRequestSubscription.id)):
            unique.setdefault(subscription.slack_user_id, subscription)
        return list(unique.values())

    def _send_user(self, kind: str, message: str, slack_user_id: str, **extra: Any) -> None:
        body = json.dumps({"message": message, **extra, "slack_user_id": slack_user_id})
        metrics.track_slack(kind, lambda: self._post("/github/user", body))

    def _pr_url(self, pr: PullRequest) -> str:
        return f"https://github.com/{pr.repository}/pull/{pr.github_pr_id}"

    def _generate_notification_message(self, job: CiJob, status: str) -> str:
        assert job.check_suite is not None and job.check_suite.pull_request is not None
        pr = job.check_suite.pull_request
        pr_url = f"{self._pr_url(pr)}/checks?check_run_id={job.check_ref}"
        link = self.settings.browse_url(job.job_ref)
        return f"PR <{pr_url}|#{pr.github_pr_id}>. <{link}|{job.name} - {status}> "

    def _invalid_rerun_message(self, stage: Stage) -> str:
        assert stage.check_suite is not None and stage.check_suite.pull_request is not None
        pr = stage.check_suite.pull_request
        reason = f"PR <{self._pr_url(pr)}|#{pr.github_pr_id}> tried to perform a partial rerun, but there were still tests running."
        self.log.info("enqueued - stage %s Reason: %s", stage.id, reason)
        return reason

    # ------------------------------------------------------------------ notifications
    def invalid_rerun_group(self, stage: Stage) -> str | None:
        assert stage.check_suite is not None
        if not self._current_execution(stage.check_suite):
            return None
        reason = self._invalid_rerun_message(stage)
        metrics.track_slack("invalid_rerun_comment", lambda: self._post("/github/comment", reason))
        return reason

    def invalid_rerun_dm(self, stage: Stage, subscription: PullRequestSubscription) -> None:
        assert stage.check_suite is not None
        if not self._current_execution(stage.check_suite):
            return
        reason = self._invalid_rerun_message(stage)
        self._send_user("invalid_rerun_dm", reason, subscription.slack_user_id)

    def notify_errors(self, job: CiJob) -> None:
        self._notify_job(job, "error", ("all", "errors"))

    def notify_cancelled(self, job: CiJob) -> None:
        self._notify_job(job, "cancelled", ("all", "errors"))

    def notify_success(self, job: CiJob) -> None:
        assert job.check_suite is not None and job.check_suite.pull_request is not None
        if not self._current_execution(job.check_suite):
            return
        message = self._generate_notification_message(job, "Success")
        for subscription in self._subscriptions(job.check_suite.pull_request, ("all", "pass")):
            self._send_user("success", message, subscription.slack_user_id, unfurl_links=False, unfurl_media=False)

    def _notify_job(self, job: CiJob, kind: str, notifications: tuple[str, ...]) -> None:
        assert job.check_suite is not None and job.check_suite.pull_request is not None
        if not self._current_execution(job.check_suite):
            return
        message = self._generate_notification_message(job, "Failed")
        for subscription in self._subscriptions(job.check_suite.pull_request, notifications):
            self._send_user(kind, message, subscription.slack_user_id)

    def execution_started_notification(self, check_suite: CheckSuite) -> None:
        self._started_finished(check_suite, "Started")

    def execution_finished_notification(self, check_suite: CheckSuite) -> None:
        self._started_finished(check_suite, "Finished")

    def _started_finished(self, check_suite: CheckSuite, status: str) -> None:
        if not self._current_execution(check_suite):
            return
        pr = check_suite.pull_request
        assert pr is not None
        link = self.settings.browse_url(check_suite.bamboo_ci_ref)
        message = f"PR <{self._pr_url(pr)}|#{pr.github_pr_id}>. <{link}|{status}> "
        for subscription in self._subscriptions(pr):
            self._send_user(status.lower(), message, subscription.slack_user_id)

    def stage_finished_notification(self, stage: Stage) -> None:
        self._stage_notification(stage)

    def stage_in_progress_notification(self, stage: Stage) -> None:
        self._stage_notification(stage)

    def _stage_notification(self, stage: Stage) -> None:
        assert stage.check_suite is not None and stage.check_suite.pull_request is not None
        if not self._current_execution(stage.check_suite):
            return
        pr = stage.check_suite.pull_request
        link = self.settings.browse_url(stage.check_suite.bamboo_ci_ref)
        message = (
            f"PR <{self._pr_url(pr)}|#{pr.github_pr_id}>. Stage: <{link}|[CI] {stage.name} - {stage.state.label}> "
        )
        for subscription in self._subscriptions(pr):
            self._send_user("stage", message, subscription.slack_user_id)
