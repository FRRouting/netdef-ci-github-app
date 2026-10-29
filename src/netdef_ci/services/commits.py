#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/commits.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Pull request commit lookups (port of Github::Parsers::PullRequestCommit)."""

from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.services.common import find_pull_request


class PullRequestCommit:
    def __init__(self, session: Session, repo: str, pr_id: int) -> None:
        self.repo = repo
        self.pr_id = pr_id
        pull_request = find_pull_request(session, pr_id, repo)
        if pull_request is None:
            raise LookupError(f"PullRequest {repo}#{pr_id} not found")
        self.github = container.github(pull_request.last_check_suite())

    def find_by_sha(self, sha: str | None) -> dict[str, Any] | None:
        if sha is None:
            return None
        page = 1
        while True:
            commits = self.github.fetch_pull_request_commits(self.pr_id, self.repo, page)
            if not commits:
                return None
            for entry in commits:
                if sha in entry["sha"][:8]:
                    return entry
            page += 1
