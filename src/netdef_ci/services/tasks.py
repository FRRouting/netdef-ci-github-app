#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/tasks.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Logic of the periodic/background jobs: CiJobStatus, TimeoutExecution, topotest failure fetching,
Slack username resolution and the cron-style WatchDog / PrBambooSync / SingleSync scripts."""

from __future__ import annotations

from datetime import timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container, metrics
from netdef_ci.config import get_settings
from netdef_ci.db import utcnow
from netdef_ci.enums import Status
from netdef_ci.jobs import queue as jobs_queue
from netdef_ci.logs import Log
from netdef_ci.models import CheckSuite, CiJob, GithubUser, PullRequest, Stage, TopotestFailure
from netdef_ci.services.finished import Finished
from netdef_ci.services.summary import Summary


# ---------------------------------------------------------------------------- CiJobStatus
def ci_job_status(session: Session, bamboo_ci_ref: str, ci_job_id: int) -> None:
    log = Log("ci_job_status")
    log.info("CiJobStatus::Update: check suite %s -> '%s'", bamboo_ci_ref, ci_job_id)
    job = session.get(CiJob, ci_job_id)
    if job is None:
        raise LookupError(f"CiJob {ci_job_id} not found")
    Summary(job).build_summary()
    session.refresh(job)
    if not job.is_finished():
        return
    log.info("Github::PlanExecution::Finished: '%s'", bamboo_ci_ref)
    Finished(session, {"bamboo_ref": bamboo_ci_ref}).finished()


# ---------------------------------------------------------------------------- TimeoutExecution
def timeout_execution(session: Session, check_suite_id: int) -> bool:
    log = Log("timeout_execution_worker")
    check_suite = session.get(CheckSuite, check_suite_id)
    if check_suite is None:
        raise LookupError(f"CheckSuite {check_suite_id} not found")
    settings = get_settings()
    finished = check_suite.is_finished()
    log.info("Timeout execution for check_suite_id: %s -> finished? %s", check_suite_id, finished)
    if finished:
        return False
    last_update = check_suite.last_job_updated_at() or check_suite.updated_at
    if last_update < utcnow() - timedelta(hours=settings.timeout_hang_hours):
        metrics.CI_TIMEOUTS.inc()
        Finished(session, {"check_suite_id": check_suite.id, "hanged": True}).finished()
        return True
    log.info("Rescheduling check_suite_id: %s", check_suite_id)
    jobs_queue.enqueue(
        session,
        "timeout_execution",
        [check_suite_id],
        queue="timeout_execution",
        delay_seconds=settings.timeout_check_minutes * 60,
    )
    return False


# ---------------------------------------------------------------------------- topotest failures
def retrieve_failures(job: CiJob) -> list[dict[str, Any]]:
    output = container.bamboo().result(job.job_ref or "") or {}
    failed = ((output.get("testResults") or {}).get("failedTests") or {}).get("testResult") or []
    failures = []
    for result in failed:
        errors = (result.get("errors") or {}).get("error") or []
        try:
            duration = int(float(result.get("durationInSeconds") or 0))
        except TypeError, ValueError:
            duration = 0
        failures.append(
            {
                "suite": result.get("className"),
                "case": result.get("methodName"),
                "message": "\n".join(str(e.get("message")) for e in errors),
                "execution_time": duration,
            }
        )
    return failures


def fetch_topotest_failures(session: Session, ci_job_id: int, count: int) -> None:
    job = session.get(CiJob, ci_job_id)
    if job is None:
        raise LookupError(f"CiJob {ci_job_id} not found")
    failures = retrieve_failures(job)
    if count > 3:
        return
    if not failures:
        count += 1
        jobs_queue.enqueue(
            session,
            "fetch_topotest_failures",
            [job.id, count],
            queue="fetch_topotest_failures",
            delay_seconds=5 * count * 60,
        )
        return
    for failure in failures:
        session.add(
            TopotestFailure(
                ci_job_id=job.id,
                test_suite=failure["suite"] or "",
                test_case=failure["case"] or "",
                message=failure["message"],
                execution_time=failure["execution_time"],
            )
        )
    session.commit()


# ---------------------------------------------------------------------------- Slack username
def slack_username_to_id(session: Session, username: str, slack_name: str) -> bool:
    log = Log("slack_username_to_id")
    user = session.scalars(select(GithubUser).where(GithubUser.github_login == username).limit(1)).first()
    if user is None:
        return False
    user.slack_id = container.slack().find_user_id_by_name(slack_name)
    log.info("Username: '%s' -> '%s'", username, user.slack_id)
    session.commit()
    return True


# ---------------------------------------------------------------------------- WatchDog (cron)
def watch_dog(session: Session) -> int:
    log = Log("watch_dog")
    log.info(">>> Running watchdog")
    ids = list(
        session.scalars(
            select(CheckSuite.id)
            .join(Stage, Stage.check_suite_id == CheckSuite.id)
            .where(Stage.status.in_([Status.QUEUED, Status.IN_PROGRESS]), CheckSuite.created_at <= utcnow())
            .distinct()
            .order_by(CheckSuite.id)
        )
    )
    log.info(">>> Suites that need to be updated: %s", len(ids))
    for suite in session.scalars(select(CheckSuite).where(CheckSuite.id.in_(ids)).order_by(CheckSuite.id)):
        log.info(">>> Updating suite: %s", suite.id)
        try:
            Finished(session, {"bamboo_ref": suite.bamboo_ci_ref, "check_suite_id": suite.id}).finished()
        except Exception as error:
            session.rollback()
            log.error("WatchDog failed for suite %s: %s: %s", suite.id, type(error).__name__, error)
    log.info(">>> Stopping watchdog")
    return len(ids)


# ---------------------------------------------------------------------------- PrBambooSync (cron)
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
    except TypeError, ValueError:
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
                runs = (github.check_runs_for_ref(repo, sha, status="in_progress").get("check_runs") or []) + (
                    github.check_runs_for_ref(repo, sha, status="queued").get("check_runs") or []
                )
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


# ---------------------------------------------------------------------------- SingleSync (manual)
def single_sync(session: Session, bamboo_ci: str, out: Any = print) -> bool:
    check_suite = session.scalars(select(CheckSuite).where(CheckSuite.bamboo_ci_ref == bamboo_ci).limit(1)).first()
    if check_suite is None:
        out("Please inform the CI that you would like to sync like the example: TESTING-GITHUBCHECKBETA-82")
        return False
    result = container.bamboo().get_status(bamboo_ci) or {}
    github = container.github(check_suite)
    settings = get_settings()
    for stage in (result.get("stages") or {}).get("stage") or []:
        for item in (stage.get("results") or {}).get("result") or []:
            ref = item.get("buildResultKey")
            ci_job = session.scalars(
                select(CiJob).where(CiJob.job_ref == ref, CiJob.check_suite_id == check_suite.id).limit(1)
            ).first()
            if ci_job is None:
                ci_job = CiJob(
                    check_suite_id=check_suite.id, name=(item.get("plan") or {}).get("shortName"), job_ref=ref
                )
                session.add(ci_job)
                session.commit()
                out(f">>> Creating CiJob {ci_job.id}, status: {item.get('state')}")
            elif ci_job.is_finished():
                continue
            url = settings.browse_url(ci_job.job_ref)
            output = {
                "title": ci_job.name,
                "summary": f"Details at [{url}]({url})\nUnfortunately we were unable to access the execution results.",
            }
            state = item.get("state")
            if state == "Unknown":
                ci_job.cancelled(github, output)
            elif state == "Failed":
                ci_job.failure(github, output)
            elif state == "Successful":
                ci_job.success(github, output)
            else:
                out("Ignored")
    return True
