#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/create_execution_by_command.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Re-run requested through the Checks UI, check_suite `rerequested` (port of workers/create_execution_by_command.rb)."""

from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.github.re_run.base import RerunBase
from netdef_ci.helpers.db import session_scope
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CheckSuite, Plan

Response = tuple[int, str]


class CreateExecutionByCommand(RerunBase):
    """Re-run requested through the Checks UI (check_suite `rerequested`)."""

    QUEUE = "create_execution_by_command"

    @classmethod
    def run(cls, session: Session, plan_id: int, check_suite_id: int, payload: dict[str, Any]) -> Response:
        check_suite = session.get(CheckSuite, check_suite_id)
        plan = session.get(Plan, plan_id)
        if check_suite is None or plan is None:
            return 404, "Failed to fetch a check suite"
        instance = cls(session, payload, Log("github_rerun_command"))
        assert check_suite.pull_request is not None
        with pull_request_lock(check_suite.pull_request.id):
            failed = instance.execute(plan, check_suite)
        return failed or (200, "Starting re-run (command)")

    def execute(self, plan: Plan, old_suite: CheckSuite) -> Response | None:
        self.github = container.github(old_suite)
        self.stop_previous_execution(plan)
        check_suite = self.copy_check_suite(old_suite)
        # This suite is not linked to `plan` (plan_id stays NULL).
        status = self.start_new_execution(check_suite, plan)
        if status != 200:  # no Bamboo execution exists: do not create stages/check runs for it
            return (status, "Failed to create CI Plan")
        self.ci_jobs(check_suite, plan)
        return None


@job_handler("create_execution_by_command")
def create_execution_by_command_job(plan_id: int, check_suite_id: int, payload: dict[str, Any]) -> None:
    with session_scope() as session:
        CreateExecutionByCommand.run(session, plan_id, check_suite_id, payload)
