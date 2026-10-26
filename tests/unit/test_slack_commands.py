#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_slack_commands.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from sqlalchemy import select

from netdef_ci.enums import Status
from netdef_ci.models import PullRequestSubscription
from netdef_ci.services import slack_commands as sc
from tests import factories as f


def test_running_lists_prs_with_queued_or_running_jobs(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    f.World(session, statuses=(Status.SUCCESS, Status.SUCCESS))  # finished: not listed
    text = sc.running(session, {"github_user": "alice", "event": {}})
    assert text.startswith("```|     PR ID     |") and text.endswith("```")
    assert f"https://github.com/org/repo/pull/{w.pr.github_pr_id}" in text
    assert text.count("\n|") == 2 + 0  # header separator + one row
    assert sc.running(session, {"github_user": "nobody"}) == "No running PR"


def test_settings_table_and_empty_state(session) -> None:
    assert sc.settings(session, {"slack_user_id": "U1"}) == "You don't have any subscription"
    session.add_all(
        [
            PullRequestSubscription(slack_user_id="U1", rule="notify", target="12", notification="all"),
            PullRequestSubscription(slack_user_id="U1", rule="user", target="alice", notification="errors"),
            PullRequestSubscription(slack_user_id="U2", rule="notify", target="99", notification="all"),
        ]
    )
    session.commit()
    text = sc.settings(session, {"slack_user_id": "U1"})
    assert "| Pull Request | 12" in text and "| GitHub User  | alice" in text and "99" not in text


def test_subscribe_lifecycle(session, clients) -> None:
    payload = {"rule": "notify", "target": 12, "notification": "all", "slack_user_id": "U1"}
    assert sc.subscribe(session, payload) == "Subscription created"
    assert sc.subscribe(session, {**payload, "notification": "errors"}) == "Subscription updated"
    assert session.scalars(select(PullRequestSubscription)).one().notification == "errors"
    assert sc.subscribe(session, {**payload, "notification": "off"}) == "Unsubscribed"
    assert session.scalars(select(PullRequestSubscription)).all() == []
    assert sc.subscribe(session, {**payload, "notification": "off"}) == "Unsubscribed"


def test_user_rule_requires_an_existing_github_user(session, clients, github) -> None:
    f.World(session)
    payload = {"rule": "user", "target": "alice", "notification": "all", "slack_user_id": "U1"}
    assert sc.subscribe(session, payload) == "Subscription created"
    github.fetch_username = lambda _t: None
    assert sc.subscribe(session, {**payload, "target": "ghost"}) == "Invalid GitHub username"
    assert len(session.scalars(select(PullRequestSubscription)).all()) == 1


def test_user_rule_without_any_repository_is_invalid(session, clients) -> None:
    payload = {"rule": "user", "target": "alice", "notification": "all", "slack_user_id": "U1"}
    assert sc.subscribe(session, payload) == "Invalid GitHub username"
