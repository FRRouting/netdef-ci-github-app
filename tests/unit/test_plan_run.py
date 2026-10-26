#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_plan_run.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest

from netdef_ci.services.plan_run import PlanRun
from tests import factories as f


@pytest.fixture
def run(session, clients):
    w = f.World(session)
    w.suite.bamboo_ci_ref = None
    session.commit()
    return w, PlanRun(w.suite, w.plan)


def test_success_stores_reference_and_comments_on_bamboo(run, bamboo, session) -> None:
    w, plan_run = run
    plan_run.ci_variables = [{"name": "signature_secret", "value": "x"}]
    assert plan_run.start_plan() == 200
    session.refresh(w.suite)
    assert w.suite.bamboo_ci_ref == "PROJ-PLAN-1"
    key, comment = bamboo.comments[0]
    assert key == "PROJ-PLAN-1"
    assert f"GitHub Merge Request {w.pr.github_pr_id} (https://github.com/org/repo/pull/{w.pr.github_pr_id})" in comment
    assert f"Merge Git Commit ID {w.suite.commit_sha_ref} on top of base Git Commit ID {'b' * 40}" in comment
    assert bamboo.submissions[0]["variables"] == [{"name": "signature_secret", "value": "x"}]


def test_created_201_is_also_success(run, bamboo) -> None:
    bamboo.submit_status = 201
    assert run[1].start_plan() == 200


@pytest.mark.parametrize(
    ("status", "text", "expected"),
    [
        (400, "bad", 400),
        (404, "missing", 404),
        (500, "boom", 500),
        (503, "unavailable", 503),
        (400, "You have reached the maximum number of concurrent builds", 429),
    ],
)
def test_failures_map_to_status_codes(run, bamboo, status, text, expected) -> None:
    bamboo.submit_status, bamboo.submit_text = status, text
    assert run[1].start_plan() == expected
    assert bamboo.comments == []


def test_unreachable_bamboo_is_418(run, bamboo) -> None:
    bamboo.unreachable = True
    assert run[1].start_plan() == 418
