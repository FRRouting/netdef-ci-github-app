#  SPDX-License-Identifier: BSD-2-Clause
#
#  enums.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Status enumerations shared by CiJob, Stage and AuditStatus (same integers as the Ruby schema)."""

from __future__ import annotations

import enum


class Status(enum.IntEnum):
    QUEUED = 0
    IN_PROGRESS = 1
    SUCCESS = 2
    REFRESH = 3  # AuditStatus only
    CANCELLED = -1
    FAILURE = -2
    SKIPPED = -3

    @property
    def label(self) -> str:
        return self.name.lower()


RUNNING_STATUSES = (Status.QUEUED, Status.IN_PROGRESS)
# CiJob.failure scope in the Ruby code: anything that did not succeed and is not running.
FAILED_STATUSES = (Status.FAILURE, Status.CANCELLED, Status.SKIPPED)
