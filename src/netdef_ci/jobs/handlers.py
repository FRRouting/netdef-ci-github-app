#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/handlers.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Registered background job handlers (one function per job type)."""

from __future__ import annotations

from typing import Any

from netdef_ci.db import session_scope
from netdef_ci.jobs.registry import HANDLERS, job_handler
from netdef_ci.services import executions, tasks


@job_handler("create_execution_by_plan")
def create_execution_by_plan(pull_request_id: int, payload: dict[str, Any], plan_id: int) -> None:
    with session_scope() as session:
        executions.CreateExecutionByPlan.run(session, pull_request_id, payload, plan_id)


@job_handler("create_execution_by_comment")
def create_execution_by_comment(pull_request_id: int, payload: dict[str, Any], plan_id: int) -> None:
    with session_scope() as session:
        executions.CreateExecutionByComment.run(session, pull_request_id, payload, plan_id)


@job_handler("create_execution_by_command")
def create_execution_by_command(plan_id: int, check_suite_id: int, payload: dict[str, Any]) -> None:
    with session_scope() as session:
        executions.CreateExecutionByCommand.run(session, plan_id, check_suite_id, payload)


@job_handler("ci_job_status")
def ci_job_status(bamboo_ci_ref: str, ci_job_id: int) -> None:
    with session_scope() as session:
        tasks.ci_job_status(session, bamboo_ci_ref, ci_job_id)


@job_handler("timeout_execution")
def timeout_execution(check_suite_id: int) -> None:
    with session_scope() as session:
        tasks.timeout_execution(session, check_suite_id)


@job_handler("fetch_topotest_failures")
def fetch_topotest_failures(ci_job_id: int, count: int) -> None:
    with session_scope() as session:
        tasks.fetch_topotest_failures(session, ci_job_id, count)


@job_handler("slack_username_to_id")
def slack_username_to_id(username: str, slack_name: str) -> None:
    with session_scope() as session:
        tasks.slack_username_to_id(session, username, slack_name)


REGISTERED = tuple(sorted(HANDLERS))
