#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_bamboo_client.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import base64

import httpx
import pytest
import respx

from netdef_ci.clients.bamboo import BambooClient
from netdef_ci.config import get_settings
from tests import factories as f

BASE = "https://127.0.0.1"


@pytest.fixture
def router():
    with respx.mock(assert_all_called=False) as r:
        yield r


@pytest.fixture
def client(router) -> BambooClient:
    sleeps: list[float] = []
    c = BambooClient(get_settings(), sleep=sleeps.append)
    c.slept = sleeps  # type: ignore[attr-defined]
    return c


def test_submit_sends_branch_repo_shas_and_signature_secret(session, router, client) -> None:
    w = f.World(session)
    w.pr.repository = "org/repo"
    route = router.post(f"{BASE}/rest/api/latest/queue/PROJ-PLAN").respond(200, json={"buildResultKey": "PROJ-PLAN-9"})
    response = client.submit_pr_to_ci(w.suite, w.plan, [{"name": "signature_secret", "value": "s3 cret&x"}])
    assert response.status_code == 200
    request = route.calls.last.request
    params = dict(request.url.params)
    assert params["customRevision"] == "main"
    assert params["bamboo.variable.github_repo"] == "org/repo"
    assert params["bamboo.variable.github_pullreq"] == str(w.pr.github_pr_id)
    assert params["bamboo.variable.github_merge_sha"] == w.suite.commit_sha_ref
    assert params["bamboo.variable.github_base_sha"] == "b" * 40
    assert params["bamboo.variable.github_signature_secret"] == "s3 cret&x"  # percent-encoded on the wire
    assert request.headers["accept"] == "application/json"
    expected = "Basic " + base64.b64encode(b"bamboo:bamboopass").decode()
    assert request.headers["authorization"] == expected


def test_comment_body_is_xml_escaped(router, client) -> None:
    route = router.post(f"{BASE}/rest/api/latest/result/PROJ-1/comment").respond(200)
    client.add_comment_to_ci("PROJ-1", "a <b> & `c`")
    assert route.calls.last.request.content == b"<comment><content>a &lt;b&gt; &amp; `c`</content></comment>"
    assert route.calls.last.request.headers["content-type"] == "application/xml"


def test_get_json_returns_none_on_errors(router, client) -> None:
    router.get(f"{BASE}/rest/api/latest/result/A-1").respond(200, text="<html>not json</html>")
    router.get(f"{BASE}/rest/api/latest/result/B-1").mock(side_effect=httpx.ConnectError("down"))
    assert client.get_status("A-1") is None
    assert client.get_status("B-1") is None


def test_running_plan_extracts_jobs_by_stage(router, client) -> None:
    router.get(f"{BASE}/rest/api/latest/result/PROJ-PLAN-1").respond(
        200,
        json={
            "stages": {
                "stage": [
                    {
                        "results": {
                            "result": [{"key": "PROJ-PLAN-JOB1-1", "stage": "Build", "plan": {"shortName": "Job 1"}}]
                        }
                    },
                    {
                        "results": {
                            "result": [{"key": "PROJ-PLAN-JOB2-1", "stage": "Tests", "plan": {"shortName": "Job 2"}}]
                        }
                    },
                ]
            }
        },
    )
    assert client.running_plan("PROJ-PLAN-1") == [
        {"name": "Job 1", "job_ref": "PROJ-PLAN-JOB1-1", "stage": "Build"},
        {"name": "Job 2", "job_ref": "PROJ-PLAN-JOB2-1", "stage": "Tests"},
    ]
    router.get(f"{BASE}/rest/api/latest/result/EMPTY-1").respond(200, json={})
    assert client.running_plan("EMPTY-1") == []


def test_restart_rerun_stop_and_status_endpoints(router, client) -> None:
    restart = router.put(f"{BASE}/rest/api/latest/queue/PROJ-PLAN-1").respond(200, text="ok")
    assert client.restart("PROJ-PLAN-1").status_code == 200
    assert dict(restart.calls.last.request.url.params) == {"executeAllStages": "true"}
    assert client.rerun("PROJ-PLAN-1") == "ok"
    assert dict(restart.calls.last.request.url.params) == {"executeAllStages": "true", "orphanRemoval": "true"}
    stop = router.get(f"{BASE}/build/admin/stopPlan.action").respond(200, text="<html/>")
    client.stop_plan("PROJ-PLAN-1")
    assert dict(stop.calls.last.request.url.params) == {"planResultKey": "PROJ-PLAN-1"}
    router.delete(f"{BASE}/rest/api/latest/queue/PROJ-JOB-1").respond(200)
    assert client.stop_job("PROJ-JOB-1").status_code == 200
    router.get(f"{BASE}/rest/api/latest/result/status/PROJ-PLAN-1").respond(200, json={"currentStage": "Final"})
    assert client.build_status("PROJ-PLAN-1") == {"currentStage": "Final"}


def test_write_errors_return_none_instead_of_raising(router, client) -> None:
    router.post(f"{BASE}/rest/api/latest/queue/X").mock(side_effect=httpx.ConnectError("down"))
    assert client._write("POST", "/rest/api/latest/queue/X") is None


def test_build_log_returns_last_ten_lines_with_bounded_retries(router, client) -> None:
    lines = "\n".join(f"l{i}" for i in range(30))
    route = router.get("https://ci1.example/log")
    route.side_effect = [httpx.Response(200, text=""), httpx.Response(500, text=""), httpx.Response(200, text=lines)]
    assert client.build_log("https://ci1.example/log") == "\n".join(f"l{i}" for i in range(20, 30))
    assert client.slept == [5, 5]
    route.side_effect = None
    route.respond(200, text="")
    client.slept.clear()
    assert client.build_log("https://ci1.example/log") == ""
    assert client.slept == [5, 5, 5]  # 4 attempts in total


def test_cancel_comment_links_the_new_execution(session, router, client) -> None:
    w = f.World(session)
    new = f.check_suite(session, w.pr, w.plan, ref="PROJ-PLAN-99")
    route = router.post(f"{BASE}/rest/api/latest/result/PROJ-PLAN-77/comment").respond(200)
    client.comment_cancelled(w.suite, new)
    assert b"https://ci.example.test/browse/PROJ-PLAN-99" in route.calls.last.request.content


@pytest.mark.parametrize(
    ("status", "body", "expected"),
    [
        (200, {"lifeCycleState": "Finished"}, True),
        (200, {"lifeCycleState": "NotBuilt"}, True),
        (200, {"lifeCycleState": "InProgress"}, False),
        (200, {"lifeCycleState": "Queued"}, False),
        (404, {"message": "Result PROJ-PLAN-5 not found"}, True),
        (500, {"message": "boom"}, False),
    ],
)
def test_is_stopped_only_trusts_finished_or_removed_results(router, client, status, body, expected) -> None:
    router.get(f"{BASE}/rest/api/latest/result/PROJ-PLAN-5").respond(status, json=body)
    assert client.is_stopped("PROJ-PLAN-5") is expected


def test_is_stopped_is_false_when_bamboo_is_unreachable(router, client) -> None:
    router.get(f"{BASE}/rest/api/latest/result/PROJ-PLAN-5").mock(side_effect=httpx.ConnectTimeout("timeout"))
    assert client.is_stopped("PROJ-PLAN-5") is False
