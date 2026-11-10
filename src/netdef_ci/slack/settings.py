#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack/settings.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack `/settings` command: the subscriptions of a Slack user (port of Slack::Settings)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.models import PullRequestSubscription
from netdef_ci.slack.formatting import padding


def settings(session: Session, payload: dict[str, Any]) -> str:
    subscriptions = list(
        session.scalars(
            select(PullRequestSubscription)
            .where(PullRequestSubscription.slack_user_id == payload.get("slack_user_id"))
            .order_by(PullRequestSubscription.id)
        )
    )
    if not subscriptions:
        return "You don't have any subscription"
    table = "|     Type     |           Target          | Notification Level |\n"
    table += "| ------------ | ------------------------- | ------------------ |\n"
    for sub in subscriptions:
        target = sub.target + padding(sub.target, 25)
        notification = (sub.notification or "") + padding(sub.notification or "", 18)
        kind = "Pull Request" if "notify" in sub.rule else "GitHub User "
        table += f"| {kind} | {target} | {notification} |\n"
    return f"```{table}```"
