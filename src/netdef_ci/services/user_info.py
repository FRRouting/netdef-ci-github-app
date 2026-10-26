#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/user_info.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Creates/updates the GithubUser (Github::UserInfo) and links it to PR / check suite / audit retry."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.logs import Log
from netdef_ci.models import AuditRetry, CheckSuite, GithubUser, PullRequest


def sync_user_info(
    session: Session,
    github_id: int | None,
    *,
    pull_request: PullRequest | None = None,
    check_suite: CheckSuite | None = None,
    audit_retry: AuditRetry | None = None,
) -> GithubUser | None:
    log = Log("github_user_info")
    if github_id is None:
        return None
    log.info("Fetching user info for github_id: %s", github_id)
    try:
        info = container.github(check_suite).fetch_username(int(github_id))
    except Exception as error:
        log.error("GitHub user %s could not be fetched (%s: %s)", github_id, type(error).__name__, error)
        info = None
    user = session.scalars(select(GithubUser).where(GithubUser.github_id == int(github_id))).first()
    if user is None:
        user = GithubUser(github_id=int(github_id))
        session.add(user)
    if info:
        user.github_login = info.get("login")
        user.github_username = info.get("name")
        user.github_email = info.get("email")
        user.github_type = info.get("type")
        user.organization_url = info.get("organizations_url")
        user.github_organization = info.get("company")
    else:
        log.warning("GitHub user %s could not be fetched; keeping stored data", github_id)
    session.commit()
    if pull_request is not None:
        pull_request.github_user_id = user.id
    if check_suite is not None:
        check_suite.github_user_id = user.id
    if audit_retry is not None:
        audit_retry.github_user_id = user.id
    session.commit()
    return user
