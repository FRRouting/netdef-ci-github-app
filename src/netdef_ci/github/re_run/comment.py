#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/re_run/comment.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Webhook side of a `ci:rerun` comment: validate and schedule the executions, admitted by `CommandGuard`
(port of Github::ReRun::Comment)."""

from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.github.duplicate_request_guard import CommandGuard
from netdef_ci.github.re_run.base import plans_for
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig, payload_pr_id
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.models import PullRequest, find_pull_request

Response = tuple[int, str]


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
        guard = CommandGuard(self.session, pull_request.id)
        with guard.admission() as refused:
            if refused is not None:
                self._refused_reaction(pull_request, repo)
                return refused
            rocket_id = self._reaction(pull_request, repo)
            for plan in plans_for(self.session, pull_request, repo):
                guard.enqueue(
                    "create_execution_by_comment",
                    [pull_request.id, self.payload, plan.id, rocket_id],
                    queue=jobs_queue.execution_queue("create_execution_by_comment", pull_request.github_pr_id),
                    delay_seconds=get_settings().rerun_delay_seconds,
                )
        return 200, "Scheduled Plan Runs"

    def _reaction(self, pull_request: PullRequest, repo: str | None) -> int | None:
        """Rocket on the comment while the executions are being started; the execution job swaps it for +1/-1."""
        comment_id = dig(self.payload, "comment", "id")
        if comment_id is None or repo is None:
            return None
        try:
            reaction = container.github(pull_request.last_check_suite()).comment_reaction_rocket(repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)
            return None
        return reaction.get("id") if isinstance(reaction, dict) else None

    def _refused_reaction(self, pull_request: PullRequest, repo: str | None) -> None:
        """:-1: on a comment refused by `CommandGuard`, so its author knows nothing was started."""
        comment_id = dig(self.payload, "comment", "id")
        if comment_id is None or repo is None:
            return
        try:
            container.github(pull_request.last_check_suite()).comment_reaction_thumb_down(repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)
