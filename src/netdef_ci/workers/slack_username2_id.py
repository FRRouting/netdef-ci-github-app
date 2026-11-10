#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/slack_username2_id.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Resolves a Slack username to its id for a GitHub user (port of workers/slack_username2_id.rb)."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.helpers.db import session_scope
from netdef_ci.helpers.logs import Log
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import GithubUser


def slack_username_to_id(session: Session, username: str, slack_name: str) -> bool:
    log = Log("slack_username_to_id")
    user = session.scalars(select(GithubUser).where(GithubUser.github_login == username).limit(1)).first()
    if user is None:
        return False
    user.slack_id = container.slack().find_user_id_by_name(slack_name)
    log.info("Username: '%s' -> '%s'", username, user.slack_id)
    session.commit()
    return True


@job_handler("slack_username_to_id")
def slack_username_to_id_job(username: str, slack_name: str) -> None:
    with session_scope() as session:
        slack_username_to_id(session, username, slack_name)
