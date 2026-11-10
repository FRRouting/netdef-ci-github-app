#  SPDX-License-Identifier: BSD-2-Clause
#
#  helpers/payload.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Reading values out of webhook payloads (part of helpers/sinatra_payload.rb in the Ruby application)."""

from __future__ import annotations

from typing import Any


def dig(data: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(data, dict):
            return None
        data = data.get(key)
    return data


def payload_pr_id(payload: dict[str, Any]) -> int | None:
    number = dig(payload, "issue", "number")
    if number is not None:
        return int(number)
    pulls = dig(payload, "check_suite", "pull_requests")
    if isinstance(pulls, list) and pulls:
        return pulls[-1].get("number")
    return None
