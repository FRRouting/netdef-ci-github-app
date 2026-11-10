#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/finished_execution.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`finished_execution` job: a Bamboo build ended. The Ruby application runs Github::PlanExecution::Finished inside
the request, so it has no file in workers/."""

from __future__ import annotations

from typing import Any

from netdef_ci.github.plan_execution.finished import BambooUnavailable, Finished
from netdef_ci.helpers.db import session_scope
from netdef_ci.jobs.registry import job_handler


@job_handler("finished_execution")
def finished_execution_job(payload: dict[str, Any]) -> None:
    with session_scope() as session:
        status, _body = Finished(session, payload).finished()
    if status == 503:
        raise BambooUnavailable(f"Bamboo unavailable while finishing {payload.get('bamboo_ref')}")
