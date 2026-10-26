#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_finished.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from netdef_ci.enums import Status
from netdef_ci.services.finished import Finished
from tests import factories as f


def result(*pairs):
    return {"stages": {"stage": [{"results": {"result": [{"buildResultKey": k, "state": s} for k, s in pairs]}}]}}


def test_unknown_suite_is_404(session, clients) -> None:
    assert Finished(session, {"bamboo_ref": "NOPE-1"}).finished() == (404, "Check Suite not found")
    assert Finished(session, {}).finished() == (404, "Check Suite not found")


def test_running_build_is_left_alone(session, clients, bamboo, github) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {
        "currentStage": "Tests",
        "progress": {"percentageCompleted": 0.4},
        "finished": False,
    }
    assert Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished() == (200, "Still running")
    assert github.calls == []
    assert w.build_job.state == Status.IN_PROGRESS


def test_bamboo_unavailable_changes_nothing(session, clients, github) -> None:
    f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    assert Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished() == (503, "Bamboo unavailable")
    assert github.calls == []


def test_final_stage_reconciles_every_job_and_notifies(session, clients, bamboo, github, slack) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.IN_PROGRESS))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final", "finished": True}
    bamboo.results["PROJ-PLAN-77"] = result(("PROJ-PLAN-77-BLD", "Successful"), ("PROJ-PLAN-77-TST", "Failed"))
    assert Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished() == (200, "Finished")
    for obj in (w.build_job, w.tests_job, w.build_stage, w.tests_stage):
        session.refresh(obj)
    assert (w.build_job.state, w.tests_job.state) == (Status.SUCCESS, Status.FAILURE)
    assert (w.build_stage.state, w.tests_stage.state) == (Status.SUCCESS, Status.FAILURE)
    assert {"success", "errors", "finished"} <= set(slack.names())


def test_unknown_state_cancels_and_notifies(session, clients, bamboo, slack) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final"}
    bamboo.results["PROJ-PLAN-77"] = result(("PROJ-PLAN-77-BLD", "Unknown"))
    Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished()
    session.refresh(w.build_job)
    assert w.build_job.state == Status.CANCELLED and "cancelled" in slack.names()


def test_hanged_flag_forces_reconciliation_and_skips_leftovers(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Tests", "finished": False}
    bamboo.results["PROJ-PLAN-77"] = result(("PROJ-PLAN-77-BLD", "Successful"))
    assert Finished(session, {"check_suite_id": w.suite.id, "hanged": True}).finished() == (200, "Finished")
    session.refresh(w.tests_job)
    assert w.tests_job.state == Status.SKIPPED  # not present in Bamboo any more


def test_stopped_plan_or_full_progress_counts_as_ended(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.results["PROJ-PLAN-77"] = result()
    for status in ({"message": "stopped"}, {"currentStage": "Tests", "progress": {"percentageCompleted": 2.0}}):
        bamboo.statuses["PROJ-PLAN-77"] = status
        assert Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished() == (200, "Finished")
        for job in (w.build_job, w.tests_job):
            job.status = Status.IN_PROGRESS
        session.commit()


def test_bamboo_error_payload_does_not_touch_jobs(session, clients, bamboo) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    bamboo.statuses["PROJ-PLAN-77"] = {"currentStage": "Final"}
    bamboo.results["PROJ-PLAN-77"] = {"status-code": 404, "message": "not found"}
    Finished(session, {"bamboo_ref": "PROJ-PLAN-77"}).finished()
    session.refresh(w.build_job)
    assert w.build_job.state == Status.SKIPPED  # only the "deleted job" clean-up applies


def test_lookup_by_id_ignores_unrelated_suites_without_bamboo_ref(session, clients) -> None:
    w = f.World(session)
    other = f.check_suite(session, w.pr, w.plan)
    other.bamboo_ci_ref = None
    session.commit()
    assert Finished(session, {"check_suite_id": w.suite.id}).check_suite.id == w.suite.id
