#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/common.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Small query helpers shared by the services."""

from __future__ import annotations

import time
from collections.abc import Callable

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.logs import Log
from netdef_ci.models import PullRequest


def find_pull_request(session: Session, github_pr_id: int | None, repository: str | None = None) -> PullRequest | None:
    """`PullRequest.find_by(github_pr_id:)`; the repository filter (when known) avoids matching a PR with the same
    number in another repository."""
    if github_pr_id is None:
        return None
    stmt = select(PullRequest).where(PullRequest.github_pr_id == github_pr_id)
    if repository:
        stmt = stmt.where(PullRequest.repository == repository)
    return session.scalars(stmt.order_by(PullRequest.id).limit(1)).first()


def wait_for_running_jobs(
    check_suite_ref: str | None, *, sleep: Callable[[float], None] = time.sleep
) -> list[dict[str, str | None]]:
    """Jobs of a freshly queued execution. Bamboo needs a few seconds to expand the plan into stages/jobs, so the
    list is polled (bounded by RUNNING_PLAN_WAIT_SECONDS) until it is not empty; may still return []."""
    settings = get_settings()
    deadline = time.monotonic() + settings.running_plan_wait_seconds
    log = Log("running_plan")
    while True:
        jobs = container.bamboo().running_plan(check_suite_ref)
        if jobs or time.monotonic() >= deadline:
            if not jobs:
                log.warning(
                    "Bamboo listed no jobs for %s after %ss", check_suite_ref, settings.running_plan_wait_seconds
                )
            return jobs
        sleep(settings.running_plan_poll_seconds)
