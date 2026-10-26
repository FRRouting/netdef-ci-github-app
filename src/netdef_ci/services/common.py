#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/common.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Small query helpers shared by the services."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.models import PullRequest


def find_pull_request(session: Session, github_pr_id: int | None, repository: str | None = None) -> PullRequest | None:
    """`PullRequest.find_by(github_pr_id:)`; the repository filter (when known) avoids matching a PR with the same
    number in another repository, which the Ruby lookup could do."""
    if github_pr_id is None:
        return None
    stmt = select(PullRequest).where(PullRequest.github_pr_id == github_pr_id)
    if repository:
        stmt = stmt.where(PullRequest.repository == repository)
    return session.scalars(stmt.order_by(PullRequest.id).limit(1)).first()
