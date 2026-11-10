#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack/formatting.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Plain-text table helpers shared by the Slack slash commands."""

from __future__ import annotations


def padding(text: str, size: int) -> str:
    return " " * max(size - len(text), 0)
