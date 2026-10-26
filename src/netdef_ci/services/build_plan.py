#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/build_plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`pull_request` webhook handling (port of Github::BuildPlan and Github::Build::PlanRun)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.config import get_settings
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import Plan, PullRequest
from netdef_ci.services.user_info import sync_user_info

Response = tuple[int, str]
ACTIONS = ("opened", "synchronize", "reopened")


def _dig(data: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


class BuildPlan:
    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        if not payload:
            raise ValueError(f"Invalid payload:\n{payload}")
        self.session = session
        self.payload = payload
        self.log = Log("github_app")

    def create(self) -> Response:
        action = self.payload.get("action")
        if action not in ACTIONS:
            self.log.warning('Action is "%s" - ignored', action)
            return 405, f'Not dealing with action "{action or ""}" for Pull Request'
        pull_request = self._fetch_pull_request()
        if pull_request is None:
            return 422, "Invalid pull request payload"
        return self._schedule(pull_request)

    # ------------------------------------------------------------------
    def _fetch_pull_request(self) -> PullRequest | None:
        number = self.payload.get("number")
        repository = _dig(self.payload, "repository", "full_name")
        branch = _dig(self.payload, "pull_request", "head", "ref")
        pull_request = self.session.scalars(
            select(PullRequest)
            .where(PullRequest.github_pr_id == number, PullRequest.repository == repository)
            .order_by(PullRequest.id)
            .limit(1)
        ).first()
        if pull_request is not None:
            pull_request.branch_name = branch
            self._add_plans(pull_request, repository)
            return pull_request
        author = _dig(self.payload, "pull_request", "user", "login")
        if not (author and number and branch and repository):  # model validations of the Ruby app
            self.log.error("Pull request payload is missing required fields")
            return None
        pull_request = PullRequest(author=author, github_pr_id=number, branch_name=branch, repository=repository)
        self.session.add(pull_request)
        self.session.commit()
        self._add_plans(pull_request, repository)
        sync_user_info(self.session, _dig(self.payload, "pull_request", "user", "id"), pull_request=pull_request)
        return pull_request

    def _add_plans(self, pull_request: PullRequest, repository: str) -> None:
        plans = list(self.session.scalars(select(Plan).where(Plan.github_repo_name == repository).order_by(Plan.id)))
        pull_request.plans = plans  # re-assigns plans.pull_request_id (same as `pull_request.plans = plans` in Rails)
        self.session.commit()

    def _schedule(self, pull_request: PullRequest) -> Response:
        if not pull_request.plans:
            return 422, "No Plans associated with this Pull Request"
        delay = get_settings().create_execution_delay_seconds
        for plan in pull_request.plans:
            jobs_queue.enqueue(
                self.session,
                "create_execution_by_plan",
                [pull_request.id, self.payload, plan.id],
                queue="create_execution_by_plan",
                delay_seconds=delay,
                max_attempts=1,  # starts a Bamboo plan: never repeated automatically
            )
        return 200, "Scheduled Plan Runs"
