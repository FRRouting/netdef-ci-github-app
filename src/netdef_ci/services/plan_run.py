#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/plan_run.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Starts a Bamboo plan for a check suite (port of BambooCi::PlanRun)."""

from __future__ import annotations

import httpx
from sqlalchemy.orm import object_session

from netdef_ci import container
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, Plan


class PlanRun:
    def __init__(self, check_suite: CheckSuite, plan: Plan) -> None:
        assert check_suite.pull_request is not None
        self.check_suite = check_suite
        self.plan = plan
        self.ci_variables: list[dict[str, str]] = []
        self.ci_key: str | None = None
        self.response: httpx.Response | None = None
        self.log = Log("github_plan_run", check_suite.pull_request.github_pr_id)
        self.log.info("BambooCi::PlanRun - CheckSuite: %s", check_suite.id)

    def start_plan(self) -> int:
        bamboo = container.bamboo()
        self.response = bamboo.submit_pr_to_ci(self.check_suite, self.plan, self.ci_variables)
        if self.response is None:
            self.log.error("HTTP Request error")
            return 418
        code = self.response.status_code
        if code in (200, 201):
            self.ci_key = self.response.json().get("buildResultKey")
            self.check_suite.bamboo_ci_ref = self.ci_key
            session = object_session(self.check_suite)
            assert session is not None
            session.commit()
            self._generate_comment()
            return 200
        if 400 <= code <= 500:
            return self._failed()
        self.log.error("Unmapped HTTP error (Bamboo): %s (check suite %s)", code, self.check_suite.id)
        return self._failed()

    def _failed(self) -> int:
        assert self.response is not None
        self.log.debug("ci submission failed (%s): %s", self.response.status_code, self.response.text[:500])
        if "reached the maximum number of concurrent builds" in self.response.text:
            return 429
        return self.response.status_code

    def _generate_comment(self) -> None:
        pr = self.check_suite.pull_request
        assert pr is not None
        url = f"https://github.com/{pr.repository}/pull/{pr.github_pr_id}"
        comment = (
            f"GitHub Merge Request {pr.github_pr_id} ({url})\n"
            f"for GitHub Repo {pr.repository}, branch {self.check_suite.merge_branch}\n\n"
            f"Request to merge from {pr.repository}\n"
            f"Merge Git Commit ID {self.check_suite.commit_sha_ref}"
            f" on top of base Git Commit ID {self.check_suite.base_sha_ref}"
        )
        container.bamboo().add_comment_to_ci(self.ci_key, comment)
