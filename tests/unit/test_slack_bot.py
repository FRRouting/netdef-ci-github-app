#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_slack_bot.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import json

import httpx
import pytest

from netdef_ci.clients.slack import SlackBot
from netdef_ci.config import get_settings
from netdef_ci.models import PullRequestSubscription
from tests import factories as f


class Recorder:
    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.fail = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.fail:
            raise httpx.ConnectError("down")
        return httpx.Response(200, text="U123")

    def bodies(self) -> list[dict]:
        return [json.loads(r.content) for r in self.requests if r.content.startswith(b"{")]


@pytest.fixture
def rec() -> Recorder:
    return Recorder()


@pytest.fixture
def bot(rec) -> SlackBot:
    return SlackBot(get_settings(), transport=httpx.MockTransport(rec))


def subscribe(session, w, target, user, notification=None, rule="notify") -> None:
    session.add(PullRequestSubscription(slack_user_id=user, rule=rule, target=str(target), notification=notification))
    session.commit()


def test_started_goes_to_subscribers_of_pr_and_author_once_per_user(session, bot, rec) -> None:
    w = f.World(session)
    subscribe(session, w, w.pr.github_pr_id, "U1")
    subscribe(session, w, w.pr.author, "U1", rule="user")  # duplicate user
    subscribe(session, w, w.pr.author, "U2", rule="user")
    subscribe(session, w, "999", "U3")
    bot.execution_started_notification(w.suite)
    assert sorted(b["slack_user_id"] for b in rec.bodies()) == ["U1", "U2"]
    assert rec.bodies()[0]["message"] == (
        f"PR <https://github.com/org/repo/pull/{w.pr.github_pr_id}|#{w.pr.github_pr_id}>. "
        "<https://ci.example.test/browse/PROJ-PLAN-77|Started> "
    )
    request = rec.requests[0]
    assert str(request.url) == "https://slack-bot.example.test/github/user"
    assert request.headers["content-type"] == "application/xml"  # required by the Slack bot
    assert request.headers["authorization"].startswith("Basic ")


def test_nothing_is_sent_for_superseded_executions(session, bot, rec) -> None:
    w = f.World(session)
    subscribe(session, w, w.pr.github_pr_id, "U1")
    f.check_suite(session, w.pr, w.plan)  # a newer execution exists
    bot.execution_started_notification(w.suite)
    bot.notify_errors(w.build_job)
    assert rec.requests == []


def test_error_and_success_use_notification_levels(session, bot, rec) -> None:
    w = f.World(session)
    subscribe(session, w, w.pr.github_pr_id, "ERR", "errors")
    subscribe(session, w, w.pr.github_pr_id, "PASS", "pass")
    subscribe(session, w, w.pr.github_pr_id, "ALL", "all")
    subscribe(session, w, w.pr.github_pr_id, "NONE", "off")
    bot.notify_errors(w.build_job)
    assert sorted(b["slack_user_id"] for b in rec.bodies()) == ["ALL", "ERR"]
    rec.requests.clear()
    bot.notify_success(w.build_job)
    bodies = rec.bodies()
    assert sorted(b["slack_user_id"] for b in bodies) == ["ALL", "PASS"]
    assert bodies[0]["unfurl_links"] is False and "Build job - Success" in bodies[0]["message"]


def test_stage_notification_text(session, bot, rec) -> None:
    w = f.World(session)
    subscribe(session, w, w.pr.github_pr_id, "U1")
    bot.stage_finished_notification(w.build_stage)
    assert "Stage: <https://ci.example.test/browse/PROJ-PLAN-77|[CI] Build - queued>" in rec.bodies()[0]["message"]


def test_invalid_rerun_group_posts_plain_reason_to_comment_endpoint(session, bot, rec) -> None:
    w = f.World(session)
    reason = bot.invalid_rerun_group(w.build_stage)
    assert "tried to perform a partial rerun, but there were still tests running." in reason
    assert str(rec.requests[0].url).endswith("/github/comment") and rec.requests[0].content.decode() == reason


def test_delivery_failures_never_raise_and_are_counted(session, bot, rec) -> None:
    w = f.World(session)
    subscribe(session, w, w.pr.github_pr_id, "U1")
    rec.fail = True
    bot.execution_started_notification(w.suite)  # must not raise


def test_username_translation(bot, rec) -> None:
    assert bot.find_user_id_by_name("alice") == "U123"
    assert str(rec.requests[0].url) == "https://slack-bot.example.test/github/translate/alice"
