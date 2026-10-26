#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/slack_commands.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Slack slash-command handlers (port of lib/slack/{running,settings,subscribe}.rb)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.enums import RUNNING_STATUSES
from netdef_ci.models import CheckSuite, CiJob, PullRequest, PullRequestSubscription


def _padding(text: str, size: int) -> str:
    return " " * max(size - len(text), 0)


def running(session: Session, payload: dict[str, Any]) -> str:
    stmt = (
        select(PullRequest)
        .join(CheckSuite, CheckSuite.pull_request_id == PullRequest.id)
        .join(CiJob, CiJob.check_suite_id == CheckSuite.id)
        .where(PullRequest.author == payload.get("github_user"), CiJob.status.in_(list(RUNNING_STATUSES)))
        .distinct()
        .order_by(PullRequest.id)
    )
    pull_requests = list(session.scalars(stmt))
    if not pull_requests:
        return "No running PR"
    header = "|     PR ID     |                              URL                               | Tests Running or Queued |\n"
    header += "| ------------- | -------------------------------------------------------------- | ----------------------- |\n"
    rows = []
    for pr in pull_requests:
        pr_id = f"{' ' * 6}{pr.github_pr_id}"
        pr_id += _padding(pr_id, 13)
        url = f"    https://github.com/{pr.repository}/pull/{pr.github_pr_id}"
        url += _padding(url, 62)
        last = pr.last_check_suite()
        total = f"{' ' * 10}{len(last.running_jobs()) if last else 0}"
        total += _padding(total, 23)
        rows.append(f"| {pr_id} | {url} | {total} |")
    return f"```{header}{chr(10).join(rows)}```"


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
        target = sub.target + _padding(sub.target, 25)
        notification = (sub.notification or "") + _padding(sub.notification or "", 18)
        kind = "Pull Request" if "notify" in sub.rule else "GitHub User "
        table += f"| {kind} | {target} | {notification} |\n"
    return f"```{table}```"


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
    for repo in PullRequest.unique_repository_names(session):
        pr = session.scalars(select(PullRequest).where(PullRequest.repository == repo).order_by(PullRequest.id.desc())).first()
        github = container.github(pr.last_check_suite() if pr else None)
        if github.fetch_username(str(payload.get("target"))):
            return False
    return True
