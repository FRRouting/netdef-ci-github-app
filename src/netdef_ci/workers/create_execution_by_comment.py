#  SPDX-License-Identifier: BSD-2-Clause
#
#  workers/create_execution_by_comment.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`ci:rerun [#sha]` comment (port of workers/create_execution_by_comment.rb)."""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci import container
from netdef_ci.github.re_run.base import RerunBase
from netdef_ci.helpers.db import session_scope
from netdef_ci.helpers.logs import Log
from netdef_ci.helpers.payload import dig
from netdef_ci.jobs.locks import pull_request_lock
from netdef_ci.jobs.registry import job_handler
from netdef_ci.models import CheckSuite, Plan, PullRequest

Response = tuple[int, str]


class CreateExecutionByComment(RerunBase):
    """`ci:rerun [#sha]` comment."""

    QUEUE = "create_execution_by_comment"

    @classmethod
    def run(
        cls,
        session: Session,
        pull_request_id: int,
        payload: dict[str, Any],
        plan_id: int,
        rocket_reaction_id: int | None = None,
    ) -> Response:
        pull_request = session.get(PullRequest, pull_request_id)
        if pull_request is None:
            raise LookupError(f"PullRequest {pull_request_id} not found")
        instance = cls(session, payload, Log("github_rerun_comment", pull_request.github_pr_id))
        instance.pull_request = pull_request
        instance.rocket_reaction_id = rocket_reaction_id
        plan = session.get(Plan, plan_id)
        if plan is None:
            instance.finish_reaction(started=False)
            return 422, "Plan not found"
        try:
            with pull_request_lock(pull_request_id):
                return instance.execute(plan)
        finally:
            instance.finish_reaction(started=False)  # no-op when the outcome was already reported

    pull_request: PullRequest
    old_check_suite: CheckSuite | None = None
    rocket_reaction_id: int | None = None
    reaction_finished = False

    def finish_reaction(self, *, started: bool) -> None:
        """Replace the rocket added on receipt by +1 (Bamboo plan submitted) or -1 (not started). Reaction errors are
        only logged: they never change the outcome of the execution."""
        if self.reaction_finished:
            return
        self.reaction_finished = True
        comment_id = dig(self.payload, "comment", "id")
        if comment_id is None or self.repo is None:
            return
        github = container.github(self.pull_request.last_check_suite())
        if self.rocket_reaction_id is not None:
            try:
                github.delete_comment_reaction(self.repo, comment_id, self.rocket_reaction_id)
            except Exception as error:  # e.g. already removed by the job of another plan
                self.log.info("Could not remove rocket reaction from comment %s: %s", comment_id, error)
        try:
            (github.comment_reaction_thumb_up if started else github.comment_reaction_thumb_down)(self.repo, comment_id)
        except Exception as error:
            self.log.warning("Could not add reaction to comment %s: %s", comment_id, error)

    @property
    def action(self) -> str:
        return str(dig(self.payload, "comment", "body") or "")

    @property
    def sha(self) -> str | None:
        if "ci:rerun #" not in self.action.lower():
            return None
        return self.action.lower().split("#")[-1].strip() or None

    def execute(self, plan: Plan) -> Response:
        check_suite = self._check_suite_by_sha_or_comment()
        self.log.debug(">>> Check suite: %s", check_suite)
        if check_suite is None:
            return 404, "Failed to create a check suite"
        check_suite.plan_id = plan.id
        self.session.commit()
        self.stop_previous_execution(plan)
        status = self.start_new_execution(check_suite, plan)
        self.finish_reaction(started=status == 200)
        if status != 200:  # no Bamboo execution exists: do not create stages/check runs for it
            return (status, "Failed to create CI Plan")
        self.ci_jobs(check_suite, plan)
        return 201, "Starting re-run (comment)"

    def _fetch_old_check_suite(self, sha: str | None) -> CheckSuite | None:
        if sha is None:
            return None
        stmt = (
            select(CheckSuite)
            .join(PullRequest, CheckSuite.pull_request_id == PullRequest.id)
            .where(CheckSuite.commit_sha_ref.startswith(sha, autoescape=True), PullRequest.repository == self.repo)
            .order_by(CheckSuite.id.desc())
            .limit(1)
        )
        return self.session.scalars(stmt).first()

    def _check_suite_by_sha_or_comment(self) -> CheckSuite | None:
        self.old_check_suite = self._fetch_old_check_suite(self.sha)
        if self.old_check_suite is None:
            return self._comment_flow()
        self.github = container.github(self.old_check_suite)
        return self.copy_check_suite(self.old_check_suite, self.pull_request)

    def _comment_flow(self) -> CheckSuite | None:
        from netdef_ci.github.parsers.pull_request_commit import PullRequestCommit

        assert self.pr_id is not None and self.repo is not None
        commit = PullRequestCommit(self.session, self.repo, self.pr_id).find_by_sha(self.sha)
        github = container.github(self.pull_request.last_check_suite())
        info = github.pull_request_info(self.pr_id, self.repo)
        # Without an explicit sha: the head of the PR is its last commit (no paging through the commit list).
        explicit = commit and re.search(r"ci:rerun\s+#", self.action, re.I)
        sha = commit["sha"] if commit and explicit else dig(info, "head", "sha")
        if not sha:
            return None
        check_suite = CheckSuite(
            pull_request_id=self.pull_request.id,
            author=dig(self.payload, "comment", "user", "login"),
            commit_sha_ref=sha,
            work_branch=dig(info, "head", "ref"),
            base_sha_ref=dig(info, "base", "sha"),
            merge_branch=dig(info, "base", "ref"),
            re_run=True,
        )
        if not check_suite.author:
            return None
        self.session.add(check_suite)
        self.session.commit()
        self.github = container.github(check_suite)
        return check_suite


@job_handler("create_execution_by_comment")
def create_execution_by_comment_job(
    pull_request_id: int, payload: dict[str, Any], plan_id: int, rocket_reaction_id: int | None = None
) -> None:
    with session_scope() as session:
        CreateExecutionByComment.run(session, pull_request_id, payload, plan_id, rocket_reaction_id)
