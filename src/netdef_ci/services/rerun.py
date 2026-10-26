#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/rerun.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Webhook side of `ci:rerun` (comment) and check_suite re-requests: validate and schedule the executions
(port of Github::ReRun::Command and Github::ReRun::Comment)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, Plan, PullRequest
from netdef_ci.services.common import find_pull_request
from netdef_ci.services.executions import dig, payload_pr_id

Response = tuple[int, str]


def _plans_for(session: Session, pull_request: PullRequest, repo: str | None) -> list[Plan]:
    return list(pull_request.plans) or list(
        session.scalars(select(Plan).where(Plan.github_repo_name == repo).order_by(Plan.id))
    )


class ReRunCommand:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        self.payload = payload
        self.log = Log("github_rerun_command")

    def start(self) -> Response:
        if not self.payload:
            return 422, "Payload can not be blank"
        pr_id, repo = payload_pr_id(self.payload), dig(self.payload, "repository", "full_name")
        sha = dig(self.payload, "check_suite", "head_sha")
        check_suite = self.session.scalars(
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(CheckSuite.commit_sha_ref == sha, PullRequest.repository == repo, PullRequest.github_pr_id == pr_id)
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()
        if check_suite is None:
            return 404, "Failed to fetch a check suite"
        assert check_suite.pull_request is not None
        for plan in _plans_for(self.session, check_suite.pull_request, repo):
            jobs_queue.enqueue(
                self.session,
                "create_execution_by_command",
                [plan.id, check_suite.id, self.payload],
                queue="create_execution_by_command",
                delay_seconds=get_settings().rerun_delay_seconds,
                max_attempts=1,
            )
        return 200, "Scheduled Plan Runs"


class ReRunComment:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        self.session = session
        self.payload = payload
        self.log = Log("github_rerun_comment")

    @property
    def action(self) -> str:
        return str(dig(self.payload, "comment", "body") or "")

    def start(self) -> Response:
        if not self.payload:
            return 422, "Payload can not be blank"
        if not ("ci:rerun" in self.action.lower() and self.payload.get("action") == "created"):
            return 404, "Action not found"
        repo = dig(self.payload, "repository", "full_name")
        pull_request = find_pull_request(self.session, payload_pr_id(self.payload), repo)
        if pull_request is None:
            return 404, "Pull Request not found"
        if not pull_request.check_suites:
            return 404, "Can not rerun a new PullRequest"
        self._reaction(pull_request, repo)
        for plan in _plans_for(self.session, pull_request, repo):
            jobs_queue.enqueue(
                self.session,
                "create_execution_by_comment",
                [pull_request.id, self.payload, plan.id],
                queue="create_execution_by_comment",
                delay_seconds=get_settings().rerun_delay_seconds,
                max_attempts=1,
            )
        return 200, "Scheduled Plan Runs"

    def _reaction(self, pull_request: PullRequest, repo: str | None) -> None:
        comment_id = dig(self.payload, "comment", "id")
        if comment_id is None or repo is None:
            return
        try:
            container.github(pull_request.last_check_suite()).comment_reaction_thumb_up(repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)
