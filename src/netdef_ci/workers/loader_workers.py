#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/loader_workers.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Imports every worker module so their `@job_handler` functions are registered (port of workers/loader_workers.rb).
The web application, the worker process and the tests import this module before running jobs."""

from __future__ import annotations

from netdef_ci.jobs.registry import HANDLERS
from netdef_ci.workers import (  # noqa: F401  (imported for their @job_handler registrations)
    ci_job_fetch_topotest_failures,
    ci_job_status,
    create_execution_by_command,
    create_execution_by_comment,
    create_execution_by_plan,
    finished_execution,
    retry_execution,
    slack_username2_id,
    timeout_execution,
)

REGISTERED = tuple(sorted(HANDLERS))
