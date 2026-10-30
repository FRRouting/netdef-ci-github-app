#  SPDX-License-Identifier: BSD-2-Clause
#
#  web/webhooks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Routing of GitHub webhook events to the services (the catch-all `POST` route) and replay protection of the GitHub
deliveries and Bamboo callbacks."""

from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, or_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from netdef_ci.config import get_settings
from netdef_ci.db import utcnow
from netdef_ci.logs import Log
from netdef_ci.models import WebhookDelivery
from netdef_ci.services.build_plan import BuildPlan
from netdef_ci.services.executions import dig
from netdef_ci.services.finished import schedule_finished
from netdef_ci.services.rerun import ReRunCommand, ReRunComment
from netdef_ci.services.retry import RetryCommand, RetryComment
from netdef_ci.services.update_status import UpdateStatus

Response = tuple[int, str]
log = Log("github_app")


BAMBOO_CALLBACK = "bamboo_callback"  # `event` of the `webhook_deliveries` rows that record Bamboo callbacks


def _record(session: Session, key: str, event: str | None) -> bool:
    session.add(WebhookDelivery(delivery_id=key, event=event))
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        return False
    return True


def register_delivery(session: Session, delivery_id: str | None, event: str | None) -> bool:
    """Opt-in de-duplication by `X-GitHub-Delivery` (WEBHOOK_DEDUPE_TTL_SECONDS > 0). Returns False for duplicates."""
    ttl = get_settings().webhook_dedupe_ttl_seconds
    if ttl <= 0 or not delivery_id:
        return True
    session.execute(
        delete(WebhookDelivery).where(
            WebhookDelivery.received_at < utcnow() - timedelta(seconds=ttl),
            or_(WebhookDelivery.event.is_(None), WebhookDelivery.event != BAMBOO_CALLBACK),
        )
    )
    return _record(session, delivery_id, event)


def forget_delivery(session: Session, delivery_id: str | None) -> None:
    """Drop the record of a delivery that failed, so GitHub's Redeliver button (same delivery id) can retry it."""
    if get_settings().webhook_dedupe_ttl_seconds <= 0 or not delivery_id:
        return
    session.execute(delete(WebhookDelivery).where(WebhookDelivery.delivery_id == delivery_id))
    session.commit()


def process(session: Session, delivery_id: str | None, event: str | None, payload: dict[str, Any]) -> Response:
    """De-duplicate the delivery and dispatch it; a delivery that fails (exception or 5xx) is not kept as seen."""
    if not register_delivery(session, delivery_id, event):
        log.warning("Duplicate delivery %s ignored", delivery_id)
        return 200, "Duplicate delivery ignored"
    try:
        status, body = dispatch(session, event, payload)
    except Exception:
        session.rollback()
        forget_delivery(session, delivery_id)
        raise
    if status >= 500:
        forget_delivery(session, delivery_id)
    return status, body


def _callback_key(raw: bytes) -> str:
    return "bamboo:" + hashlib.sha256(raw).hexdigest()


def register_callback(session: Session, raw: bytes, max_age: int) -> bool:
    """Accept each signed Bamboo callback body once (BAMBOO_CALLBACK_MAX_AGE_SECONDS > 0). Returns False for replays.

    Rows are kept for twice the accepted age so a body whose timestamp is ahead of our clock cannot outlive its row."""
    session.execute(
        delete(WebhookDelivery).where(
            WebhookDelivery.event == BAMBOO_CALLBACK,
            WebhookDelivery.received_at < utcnow() - timedelta(seconds=2 * max_age),
        )
    )
    return _record(session, _callback_key(raw), BAMBOO_CALLBACK)


def process_callback(session: Session, raw: bytes, payload: dict[str, Any], max_age: int) -> Response:
    """Route a Bamboo callback (`/update/status`); with `max_age` > 0 a body is processed once, unless it fails."""
    if max_age and not register_callback(session, raw, max_age):
        log.warning("Replayed callback ignored: ref=%s", payload.get("bamboo_ref"))
        return 200, "Duplicate callback ignored"
    try:
        if payload.get("status") == "finished":
            status, body = schedule_finished(session, payload)
        else:
            status, body = UpdateStatus(session, payload).update()
    except Exception:
        session.rollback()
        _forget_callback(session, raw, max_age)
        raise
    if status >= 500:
        _forget_callback(session, raw, max_age)
    return status, body


def _forget_callback(session: Session, raw: bytes, max_age: int) -> None:
    """A callback that failed may be sent again by Bamboo with the same body."""
    if not max_age:
        return
    session.execute(delete(WebhookDelivery).where(WebhookDelivery.delivery_id == _callback_key(raw)))
    session.commit()


def _stale_comment(payload: dict[str, Any]) -> bool:
    """With de-duplication enabled, a comment older than its window can only come from a replayed delivery."""
    ttl = get_settings().webhook_dedupe_ttl_seconds
    created = str(dig(payload, "comment", "created_at") or "")
    if ttl <= 0 or not created:
        return False
    try:
        created_at = datetime.fromisoformat(created).astimezone(UTC).replace(tzinfo=None)
    except ValueError:
        return True
    return created_at < utcnow() - timedelta(seconds=ttl)


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
        return RetryCommand(session, payload).schedule()
    if event == "installation":
        log.debug(">>> Received a new installation policy")
        return 202, "Updated"
    if event == "issue_comment":
        comment = payload.get("comment")
        if not isinstance(comment, dict):
            return 404, "Action not found"
        body = str(comment.get("body") or "").lower()
        if re.search(r"ci:(retry|rerun)", body) and _stale_comment(payload):
            log.warning("Command in comment %s older than the replay window ignored", comment.get("id"))
            return 422, "Stale comment ignored"
        if re.search(r"ci:retry", body):
            return RetryComment(session, payload).schedule()
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
