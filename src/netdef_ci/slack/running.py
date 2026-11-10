#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack/running.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack `/running` command: executions still running (port of Slack::Running)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.enums import RUNNING_STATUSES
from netdef_ci.models import CheckSuite, CiJob, PullRequest
from netdef_ci.slack.formatting import padding


def running(session: Session, payload: dict[str, Any]) -> str:
    stmt = (
        select(PullRequest)
        .join(CheckSuite, CheckSuite.pull_request_id == PullRequest.id)
        .join(CiJob, CiJob.check_suite_id == CheckSuite.id)
        .where(PullRequest.author == payload.get("github_user"), CiJob.status.in_(list(RUNNING_STATUSES)))
        .distinct()
        .order_by(PullRequest.id)
    )
    pull_requests = list(session.scalars(stmt))
    if not pull_requests:
        return "No running PR"
    header = (
        "|     PR ID     |                              URL                               | Tests Running or Queued |\n"
    )
    header += (
        "| ------------- | -------------------------------------------------------------- | ----------------------- |\n"
    )
    rows = []
    for pr in pull_requests:
        pr_id = f"{' ' * 6}{pr.github_pr_id}"
        pr_id += padding(pr_id, 13)
        url = f"    https://github.com/{pr.repository}/pull/{pr.github_pr_id}"
        url += padding(url, 62)
        last = pr.last_check_suite()
        total = f"{' ' * 10}{len(last.running_jobs()) if last else 0}"
        total += padding(total, 23)
        rows.append(f"| {pr_id} | {url} | {total} |")
    return f"```{header}{chr(10).join(rows)}```"
