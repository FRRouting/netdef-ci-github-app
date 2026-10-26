#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/skip_old_tests.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Marks check runs of this app that no longer belong to the configured stages as skipped (Build::SkipOldTests)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import object_session

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, StageConfiguration


class SkipOldTests:
    # Only queued, in_progress and
    # completed are valid values of the check-runs `status` filter.
    STATUSES = ("queued", "in_progress", "completed")

    def __init__(self, check_suite: CheckSuite) -> None:
        self.check_suite = check_suite
        self.github = container.github(check_suite)
        session = object_session(check_suite)
        assert session is not None
        configs = session.scalars(select(StageConfiguration).order_by(StageConfiguration.id))
        self.stages = {f"[CI] {config.github_check_run_name}" for config in configs}
        self.log = Log("github_skip_old_tests")
        self.app_name = get_settings().github_app_name

    def skip_old_tests(self) -> None:
        assert self.check_suite.pull_request is not None
        repo = self.check_suite.pull_request.repository
        seen: set[int] = set()
        for status in self.STATUSES:
            runs = (
                self.github.check_runs_for_ref(repo, self.check_suite.commit_sha_ref, status=status).get("check_runs")
                or []
            )
            for check_run in runs:
                if check_run["id"] in seen:
                    continue
                seen.add(check_run["id"])
                self._skip(check_run)

    def _skip(self, check_run: dict) -> None:
        if (check_run.get("app") or {}).get("name") != self.app_name or check_run["name"] in self.stages:
            return
        if check_run.get("conclusion") == "skipped":
            return
        self.log.info("Skipping old test suite: %s", check_run["name"])
        self.github.skipped(
            check_run["id"], {"title": f"{check_run['name']} summary", "summary": "Old test suite, skipping..."}
        )
