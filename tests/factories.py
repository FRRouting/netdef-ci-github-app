#  SPDX-License-Identifier: BSD-2-Clause
#
#  factories.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Builders for domain rows (FactoryBot equivalent)."""

from __future__ import annotations

import itertools
from typing import Any

from sqlalchemy.orm import Session

from netdef_ci.enums import Status
from netdef_ci.models import CheckSuite, CiJob, Plan, PullRequest, Stage, StageConfiguration

_seq = itertools.count(1)


def next_id() -> int:
    return next(_seq)


def stage_configs(session: Session, *specs: tuple[str, str, int, dict[str, Any]]) -> list[StageConfiguration]:
    """(bamboo_stage_name, github_check_run_name, position, extra) -> StageConfiguration rows."""
    rows = []
    for bamboo, github, position, extra in specs:
        row = StageConfiguration(bamboo_stage_name=bamboo, github_check_run_name=github, position=position, **extra)
        session.add(row)
        rows.append(row)
    session.commit()
    return rows


def default_stage_configs(session: Session) -> list[StageConfiguration]:
    return stage_configs(
        session,
        ("Build", "Build", 1, {"mandatory": True, "can_retry": True, "start_in_progress": False}),
        ("Tests", "Tests", 2, {"mandatory": True, "can_retry": True, "start_in_progress": False}),
    )


def plan(
    session: Session,
    repo: str = "org/repo",
    name: str = "plan-a",
    bamboo: str = "PROJ-PLAN",
    pull_request: PullRequest | None = None,
) -> Plan:
    row = Plan(
        bamboo_ci_plan_name=bamboo,
        github_repo_name=repo,
        name=name,
        pull_request_id=pull_request.id if pull_request else None,
    )
    session.add(row)
    session.commit()
    return row


def pull_request(
    session: Session, number: int | None = None, repo: str = "org/repo", author: str = "alice"
) -> PullRequest:
    row = PullRequest(author=author, github_pr_id=number or next_id() + 100, branch_name="feature", repository=repo)
    session.add(row)
    session.commit()
    return row


def check_suite(
    session: Session,
    pr: PullRequest,
    plan: Plan | None = None,
    sha: str | None = None,
    ref: str | None = None,
    **extra: Any,
) -> CheckSuite:
    row = CheckSuite(
        pull_request_id=pr.id,
        author=pr.author,
        commit_sha_ref=sha or f"{next_id():040x}",
        base_sha_ref="b" * 40,
        merge_branch="main",
        work_branch="feature",
        bamboo_ci_ref=ref or f"PROJ-PLAN-{next_id()}",
        plan_id=plan.id if plan else None,
        **extra,
    )
    session.add(row)
    session.commit()
    return row


def stage(
    session: Session,
    suite: CheckSuite,
    config: StageConfiguration | None,
    name: str | None = None,
    status: Status = Status.QUEUED,
    check_ref: str | None = None,
) -> Stage:
    row = Stage(
        check_suite_id=suite.id,
        stage_configuration_id=config.id if config else None,
        name=name or (config.github_check_run_name if config else "stage"),
        status=status,
        check_ref=check_ref,
    )
    session.add(row)
    session.commit()
    return row


def job(
    session: Session,
    suite: CheckSuite,
    stage_row: Stage | None,
    name: str | None = None,
    status: Status = Status.QUEUED,
    ref: str | None = None,
    check_ref: str | None = None,
) -> CiJob:
    row = CiJob(
        check_suite_id=suite.id,
        stage_id=stage_row.id if stage_row else None,
        name=name or f"job-{next_id()}",
        job_ref=ref or f"PROJ-PLAN-JOB{next_id()}",
        status=status,
        check_ref=check_ref,
    )
    session.add(row)
    session.commit()
    return row


class World:
    """A plan/PR/suite with two stages ("Build" -> "Tests") and one job per stage."""

    def __init__(self, session: Session, *, statuses: tuple[Status, Status] = (Status.QUEUED, Status.QUEUED)) -> None:
        self.session = session
        self.configs = default_stage_configs(session)
        self.pr = pull_request(session)
        self.plan = plan(session, pull_request=self.pr)
        self.suite = check_suite(session, self.pr, self.plan, ref="PROJ-PLAN-77")
        self.build_stage = stage(session, self.suite, self.configs[0], status=statuses[0], check_ref="501")
        self.tests_stage = stage(session, self.suite, self.configs[1], status=statuses[1], check_ref="502")
        self.build_job = job(session, self.suite, self.build_stage, "Build job", statuses[0], "PROJ-PLAN-77-BLD")
        self.tests_job = job(session, self.suite, self.tests_stage, "Tests job", statuses[1], "PROJ-PLAN-77-TST")
