#  SPDX-License-Identifier: BSD-2-Clause
#
#  web/webhooks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Routing of GitHub webhook events to the services (the `POST /*` route of the Ruby app)."""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any

from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from netdef_ci.config import get_settings
from netdef_ci.db import utcnow
from netdef_ci.logs import Log
from netdef_ci.models import WebhookDelivery
from netdef_ci.services.build_plan import BuildPlan
from netdef_ci.services.rerun import ReRunCommand, ReRunComment
from netdef_ci.services.retry import RetryCommand, RetryComment

Response = tuple[int, str]
log = Log("github_app")


def register_delivery(session: Session, delivery_id: str | None, event: str | None) -> bool:
    """Opt-in de-duplication by `X-GitHub-Delivery` (WEBHOOK_DEDUPE_TTL_SECONDS > 0). Returns False for duplicates."""
    ttl = get_settings().webhook_dedupe_ttl_seconds
    if ttl <= 0 or not delivery_id:
        return True
    session.execute(delete(WebhookDelivery).where(WebhookDelivery.received_at < utcnow() - timedelta(seconds=ttl)))
    session.add(WebhookDelivery(delivery_id=delivery_id, event=event))
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        return False
    return True


def dispatch(session: Session, event: str | None, payload: dict[str, Any]) -> Response:
    if not event:
        return 400, "Missing X-GitHub-Event header"
    event = event.lower()
    action = str(payload.get("action") or "")
    log.debug("Received event: %s", event)
    if event == "ping":
        return 200, "PONG!"
    if event == "pull_request":
        log.info("Creating new action")
        return BuildPlan(session, payload).create()
    if event == "check_run":
        log.debug("Check Run %s - %s", (payload.get("check_run") or {}).get("id"), action)
        if action.lower() != "rerequested":
            return 200, "OK"
        return RetryCommand(session, payload).start()
    if event == "installation":
        log.debug(">>> Received a new installation policy")
        return 202, "Updated"
    if event == "issue_comment":
        comment = payload.get("comment")
        if not isinstance(comment, dict):
            return 404, "Action not found"
        body = str(comment.get("body") or "").lower()
        if re.search(r"ci:retry", body):
            return RetryComment(session, payload).start()
        if re.search(r"ci:rerun", body):
            return ReRunComment(session, payload).start()
        log.debug(">>> Just a comment")
        return 200, "Just a comment"
    if event == "check_suite":
        log.debug(">>> Received a new check_suite command")
        if "rerequested" not in action.lower():
            return 200, "OK"
        return ReRunCommand(session, payload).start()
    log.debug("Unknown request %s", event)
    return 401, "Invalid request (4)"
