#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs/registry.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Job handler registry: background jobs are plain functions looked up by name."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

Handler = Callable[..., Any]
HANDLERS: dict[str, Handler] = {}


def job_handler(name: str) -> Callable[[Handler], Handler]:
    def register(func: Handler) -> Handler:
        HANDLERS[name] = func
        return func

    return register
