#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/pr_bamboo_sync.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Report of executions whose Bamboo state and database state differ (port of workers/pr_bamboo_sync.rb)."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.github.plan_execution.finished import Finished
from netdef_ci.helpers.db import utcnow
from netdef_ci.helpers.logs import Log
from netdef_ci.models import CheckSuite, PullRequest

WINDOW_START_HOURS = 24


WINDOW_END_HOURS = 2


def bamboo_finished(status: dict[str, Any] | None) -> bool:
    if not status:
        return True
    if "message" in status and "finished" not in status:
        return True
    if str(status.get("currentStage") or "").lower() == "final":
        return True
    try:
        return float((status.get("progress") or {}).get("percentageCompleted") or 0) >= 2.0
    except (TypeError, ValueError):
        return False


def classify(status: dict[str, Any] | None) -> str:
    if not status:
        return "unreachable"
    return "stale" if bamboo_finished(status) else "ok_running"


def pr_bamboo_sync(session: Session, out: Any = print) -> dict[str, list[dict[str, Any]]]:
    """Compares active GitHub check runs with Bamboo and re-syncs stale suites (workers/pr_bamboo_sync.rb)."""
    from datetime import datetime

    log = Log("pr_bamboo_sync")
    now = utcnow()
    start, end = now - timedelta(hours=WINDOW_START_HOURS), now - timedelta(hours=WINDOW_END_HOURS)
    out(f"Time window: {start} .. {end}")
    results: list[dict[str, Any]] = []
    for repo in PullRequest.unique_repository_names(session):
        suite = session.scalars(
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(PullRequest.repository == repo)
            .order_by(CheckSuite.id.desc())
            .limit(1)
        ).first()
        try:
            github = container.github(suite)
            pulls = github.pull_requests(repo)
        except Exception as error:
            log.error("Cannot process %s: %s", repo, error)
            continue
        for pr in pulls:
            updated = datetime.fromisoformat(pr["updated_at"].replace("Z", "+00:00")).replace(tzinfo=None)
            if not start <= updated <= end:
                continue
            sha = pr["head"]["sha"]
            try:
                runs = [
                    run
                    for run in github.check_runs_for_ref(repo, sha, status=None).get("check_runs") or []
                    if run.get("status") != "completed"
                ]
            except Exception as error:
                log.error("Failed fetching GitHub runs for %s: %s", sha[:8], error)
                continue
            if not runs:
                continue
            for check_suite in session.scalars(
                select(CheckSuite)
                .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
                .where(
                    PullRequest.github_pr_id == pr["number"],
                    PullRequest.repository == repo,
                    CheckSuite.commit_sha_ref == sha,
                )
            ):
                status = container.bamboo().build_status(check_suite.bamboo_ci_ref or "")
                results.append(
                    {
                        "pr_id": pr["number"],
                        "repository": repo,
                        "bamboo_ref": check_suite.bamboo_ci_ref,
                        "status": classify(status),
                        "check_suite": check_suite,
                    }
                )
    grouped: dict[str, list[dict[str, Any]]] = {"ok_running": [], "unreachable": [], "stale": []}
    for item in results:
        grouped[item["status"]].append(item)
    out(f"\nRunning (OK)   : {len(grouped['ok_running'])}\nUnreachable    : {len(grouped['unreachable'])}")
    out(f"Stale (syncing): {len(grouped['stale'])}\nTotal checked  : {len(results)}")
    for item in grouped["stale"]:
        out(f"  => PR #{item['pr_id']} ({item['repository']}) {item['bamboo_ref']}")
        try:
            Finished(session, {"bamboo_ref": item["bamboo_ref"], "hanged": True}).finished()
        except Exception as error:
            session.rollback()
            log.error("Sync failed for %s: %s", item["bamboo_ref"], error)
    for item in grouped["unreachable"]:
        out(f"  => unreachable (manual review): PR #{item['pr_id']} ({item['repository']}) {item['bamboo_ref']}")
    return grouped
