#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_build_plan.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest
from sqlalchemy import select

from netdef_ci.models import GithubUser, Job, Plan, PullRequest
from netdef_ci.services.build_plan import BuildPlan
from tests import factories as f
from tests import payloads


def test_empty_payload_is_rejected(session) -> None:
    with pytest.raises(ValueError):
        BuildPlan(session, {})


@pytest.mark.parametrize("action", ["closed", "edited", "labeled", None])
def test_other_actions_are_405(session, clients, action) -> None:
    payload = payloads.pull_request()
    payload["action"] = action
    code, body = BuildPlan(session, payload).create()
    assert code == 405 and body == f'Not dealing with action "{action or ""}" for Pull Request'
    assert session.scalars(select(PullRequest)).all() == []


def test_unplanned_repository_returns_422(session, clients) -> None:
    code, body = BuildPlan(session, payloads.pull_request()).create()
    assert (code, body) == (422, "No Plans associated with this Pull Request")
    assert session.scalars(select(PullRequest)).one().github_pr_id == 7  # PR is still recorded


@pytest.mark.parametrize("action", ["opened", "synchronize", "reopened"])
def test_valid_event_creates_pr_user_and_schedules_one_job_per_plan(session, clients, action) -> None:
    f.plan(session, name="a")
    f.plan(session, name="b", bamboo="PROJ-OTHER")
    f.plan(session, repo="other/repo", name="elsewhere")
    code, body = BuildPlan(session, payloads.pull_request(action=action)).create()
    assert (code, body) == (200, "Scheduled Plan Runs")
    pr = session.scalars(select(PullRequest)).one()
    assert (pr.author, pr.branch_name, pr.repository) == ("alice", "feature", "org/repo")
    assert len(pr.plans) == 2
    user = session.scalars(select(GithubUser)).one()
    assert user.github_id == 4242 and user.github_login == "user4242" and pr.github_user_id == user.id
    jobs = session.scalars(select(Job).order_by(Job.id)).all()
    assert [j.handler for j in jobs] == ["create_execution_by_plan"] * 2
    assert [j.queue for j in jobs] == ["create_execution_by_plan"] * 2
    assert jobs[0].args[0] == pr.id and jobs[0].args[1]["number"] == 7
    assert all(j.max_attempts == 1 for j in jobs)  # never repeat a Bamboo submission automatically


def test_existing_pr_is_updated_and_plans_move_to_the_latest_pr(session, clients) -> None:
    plan = f.plan(session)
    BuildPlan(session, payloads.pull_request(number=7)).create()
    payload = payloads.pull_request(number=8)
    BuildPlan(session, payload).create()
    first, second = session.scalars(select(PullRequest).order_by(PullRequest.id)).all()
    session.refresh(plan)
    assert plan.pull_request_id == second.id  # a plan belongs to one PR at a time
    payload = payloads.pull_request(number=7)
    payload["pull_request"]["head"]["ref"] = "renamed"
    code, _ = BuildPlan(session, payload).create()
    session.refresh(first)
    assert code == 200 and first.branch_name == "renamed" and len(first.plans) == 1
    assert session.scalars(select(GithubUser)).all().__len__() == 1


def test_missing_fields_do_not_create_a_pull_request(session, clients) -> None:
    payload = payloads.pull_request()
    del payload["pull_request"]["user"]
    assert BuildPlan(session, payload).create()[0] == 422
    assert session.scalars(select(PullRequest)).all() == []
    assert session.scalars(select(Plan)).all() == []


def test_user_lookup_failure_does_not_abort_scheduling(session, clients) -> None:
    from netdef_ci import container

    f.plan(session)

    def broken(_suite):
        raise RuntimeError("Github Authentication Failed")

    container.override(github_factory=broken)
    assert BuildPlan(session, payloads.pull_request()).create() == (200, "Scheduled Plan Runs")
    user = session.scalars(select(GithubUser)).one()
    assert user.github_id == 4242 and user.github_login is None  # row kept, details unknown
