#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/slack.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack bot notifications (port of lib/slack_bot/slack_bot.rb). Failures never propagate to the CI flow."""

from __future__ import annotations

import atexit
import functools
import json
import queue
import threading
import time
from typing import Any

import httpx
from sqlalchemy import event, select
from sqlalchemy.orm import Session, object_session

from netdef_ci import metrics
from netdef_ci.config import Settings
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, PullRequest, PullRequestSubscription, Stage

_CACHE_KEY = "netdef_slack_cache"


def _cache(session: Session) -> dict[Any, Any]:
    """Per-session memo of the lookups every notification needs (is this the current suite of the PR, who subscribed).
    A loop that notifies about many jobs runs them once; the memo is dropped at every commit/rollback, so it never
    outlives the data it was read from by more than one unit of work."""
    return session.info.setdefault(_CACHE_KEY, {})  # type: ignore[no-any-return]


@event.listens_for(Session, "after_commit")
@event.listens_for(Session, "after_rollback")
def _drop_cache(session: Session) -> None:
    session.info.pop(_CACHE_KEY, None)


OUTBOX_SIZE = 10_000
FLUSH_AT_EXIT_SECONDS = 10.0


class SlackBot:
    """Notifications are handed to one background sender thread per process (in order), so a slow or unreachable
    bot never holds the CI flows; `asynchronous=False` posts inline (tests). Pending notifications are flushed at
    interpreter exit (bounded); a process that dies abruptly loses the ones not sent yet."""

    def __init__(
        self,
        settings: Settings,
        *,
        transport: httpx.BaseTransport | None = None,
        asynchronous: bool = True,
    ) -> None:
        self.settings = settings
        self._asynchronous = asynchronous
        self._outbox: queue.Queue[tuple[str, str, str]] = queue.Queue(maxsize=OUTBOX_SIZE)
        self._sender: threading.Thread | None = None
        self._sender_lock = threading.Lock()
        self.log = Log("slack_bot")
        credentials = settings.slack_credentials()
        self._auth = (credentials.username, credentials.password) if credentials else None
        self._client = httpx.Client(
            verify=settings.slack_bot_verify_tls,
            timeout=settings.slack_timeout_seconds,
            transport=transport,
            auth=self._auth,
        )

    # ------------------------------------------------------------------ delivery
    def _deliver(self, kind: str, path: str, body: str) -> None:
        if not self._asynchronous:
            metrics.track_slack(kind, lambda: self._post(path, body))
            return
        self._start_sender()
        try:
            self._outbox.put_nowait((kind, path, body))
        except queue.Full:
            metrics.SLACK_NOTIFICATIONS.labels(type=kind, status="error").inc()
            self.log.error("Slack outbox full (%s pending); %s notification dropped", OUTBOX_SIZE, kind)

    def _start_sender(self) -> None:
        if self._sender is not None:
            return
        with self._sender_lock:
            if self._sender is None:
                self._sender = threading.Thread(target=self._send_forever, name="slack-sender", daemon=True)
                self._sender.start()
                atexit.register(self.flush, FLUSH_AT_EXIT_SECONDS)

    def _send_forever(self) -> None:
        while True:
            kind, path, body = self._outbox.get()
            try:
                metrics.track_slack(kind, functools.partial(self._post, path, body))
            finally:
                self._outbox.task_done()

    def flush(self, timeout: float) -> bool:
        """Wait (at most `timeout` seconds) until every queued notification was sent; False when some are left."""
        deadline = time.monotonic() + timeout
        while self._outbox.unfinished_tasks:
            if time.monotonic() >= deadline:
                self.log.warning("%s Slack notification(s) not sent", self._outbox.unfinished_tasks)
                return False
            time.sleep(0.01)
        return True

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
        session = object_session(pull_request)
        assert session is not None
        cache = _cache(session)
        key = ("last_suite", pull_request.id)
        if key not in cache:
            last = pull_request.last_check_suite()
            cache[key] = last.id if last is not None else 0
        return check_suite.id >= cache[key]

    @staticmethod
    def _subscriptions(
        pull_request: PullRequest, notifications: tuple[str, ...] | None = None
    ) -> list[PullRequestSubscription]:
        session = object_session(pull_request)
        assert session is not None
        cache = _cache(session)
        key = ("subscriptions", pull_request.id, notifications)
        if key in cache:
            return list(cache[key])
        stmt = select(PullRequestSubscription).where(
            PullRequestSubscription.target.in_([str(pull_request.github_pr_id), pull_request.author])
        )
        if notifications:
            stmt = stmt.where(PullRequestSubscription.notification.in_(list(notifications)))
        unique: dict[str, PullRequestSubscription] = {}
        for subscription in session.scalars(stmt.order_by(PullRequestSubscription.id)):
            unique.setdefault(subscription.slack_user_id, subscription)
        cache[key] = list(unique.values())
        return list(cache[key])

    def _send_user(self, kind: str, message: str, slack_user_id: str, **extra: Any) -> None:
        body = json.dumps({"message": message, **extra, "slack_user_id": slack_user_id})
        self._deliver(kind, "/github/user", body)

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
        self._deliver("invalid_rerun_comment", "/github/comment", reason)
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
