#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack/subscribe.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack `/subscribe` command: subscribe to notifications of a PR or GitHub user (port of Slack::Subscribe)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.models import PullRequest, PullRequestSubscription


def subscribe(session: Session, payload: dict[str, Any]) -> str:
    subscription = session.scalars(
        select(PullRequestSubscription).where(
            PullRequestSubscription.slack_user_id == payload.get("slack_user_id"),
            PullRequestSubscription.rule == payload.get("rule"),
            PullRequestSubscription.target == str(payload.get("target")),
        )
    ).first()
    notification = str(payload.get("notification") or "")
    if subscription is not None and "off" in notification:
        session.delete(subscription)
        session.commit()
        subscription = None
    if _invalid_github_user(session, payload):
        return "Invalid GitHub username"
    if subscription is None and "off" in notification:
        return "Unsubscribed"
    if subscription is None:
        created = PullRequestSubscription(
            rule=payload.get("rule") or "",
            target=str(payload.get("target")),
            slack_user_id=payload.get("slack_user_id") or "",
            notification=notification,
        )
        session.add(created)
        session.commit()
        return "Subscription created"
    subscription.notification = notification
    session.commit()
    return "Subscription updated"


def _invalid_github_user(session: Session, payload: dict[str, Any]) -> bool:
    if "notify" in str(payload.get("rule") or ""):
        return False
    # A login lookup (`/users/<login>`) is not tied to a repository: one call through the most recent pull request's
    # App is enough (the client already falls back to the other Apps when that one cannot authenticate).
    pr = session.scalars(select(PullRequest).order_by(PullRequest.id.desc()).limit(1)).first()
    if pr is None:
        return True
    github = container.github(pr.last_check_suite())
    return not github.fetch_username(str(payload.get("target")))
