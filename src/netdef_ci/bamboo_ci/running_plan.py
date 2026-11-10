#  SPDX-License-Identifier: BSD-2-Clause
#
#  bamboo_ci/running_plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Jobs of a Bamboo build that has just started (port of BambooCi::RunningPlan.fetch, with a bounded wait)."""

from __future__ import annotations

import time
from collections.abc import Callable

from netdef_ci import container
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.logs import Log


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
