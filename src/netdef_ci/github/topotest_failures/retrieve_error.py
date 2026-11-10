#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/topotest_failures/retrieve_error.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Topotest failures of a failed CI job, read from Bamboo (port of Github::TopotestFailures::RetrieveError)."""

from __future__ import annotations

from typing import Any

from netdef_ci import container
from netdef_ci.models import CiJob


def retrieve_failures(job: CiJob) -> list[dict[str, Any]]:
    output = container.bamboo().result(job.job_ref or "") or {}
    failed = ((output.get("testResults") or {}).get("failedTests") or {}).get("testResult") or []
    failures = []
    for result in failed:
        errors = (result.get("errors") or {}).get("error") or []
        try:
            duration = int(float(result.get("durationInSeconds") or 0))
        except (TypeError, ValueError):
            duration = 0
        failures.append(
            {
                "suite": result.get("className"),
                "case": result.get("methodName"),
                "message": "\n".join(str(e.get("message")) for e in errors),
                "execution_time": duration,
            }
        )
    return failures
