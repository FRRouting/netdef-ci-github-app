#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/re_run/command.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Webhook side of a check_suite re-request: validate and schedule the executions, admitted by `CommandGuard`
(port of Github::ReRun::Command)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.github.duplicate_request_guard import CommandGuard
from netdef_ci.github.re_run.base import plans_for
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig, payload_pr_id
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.models import CheckSuite, PullRequest

Response = tuple[int, str]


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
        pull_request = check_suite.pull_request
        assert pull_request is not None
        guard = CommandGuard(self.session, pull_request.id)
        with guard.admission() as refused:
            if refused is not None:
                return refused
            for plan in plans_for(self.session, pull_request, repo):
                guard.enqueue(
                    "create_execution_by_command",
                    [plan.id, check_suite.id, self.payload],
                    queue=jobs_queue.execution_queue("create_execution_by_command", pull_request.github_pr_id),
                    delay_seconds=get_settings().rerun_delay_seconds,
                )
        return 200, "Scheduled Plan Runs"
