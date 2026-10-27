#  SPDX-License-Identifier: BSD-2-Clause
#
#  fakes.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""In-memory doubles for GitHub, Bamboo and Slack (no network in any test)."""

from __future__ import annotations

from typing import Any

import httpx


class FakeGithub:
    """Stands in for `GithubCheck`; keeps every check run so tests can assert what GitHub would show."""

    def __init__(self) -> None:
        self.next_id = 1000
        self.check_runs: dict[int, dict[str, Any]] = {}
        self.calls: list[tuple[str, tuple[Any, ...]]] = []
        self.reactions: list[tuple[str, int, str]] = []
        self.users: dict[Any, dict[str, Any]] = {}
        self.commits: list[list[dict[str, Any]]] = []
        self.pr_info: dict[str, Any] = {"head": {"ref": "feature"}, "base": {"sha": "b" * 40, "ref": "main"}}
        self.listed_check_runs: dict[str, list[dict[str, Any]]] = {}
        self.pulls: list[dict[str, Any]] = []
        self.secret = "test-secret"
        self.fail_reactions = False

    # -- helpers
    def _record(self, name: str, *args: Any) -> None:
        self.calls.append((name, args))

    def calls_named(self, name: str) -> list[tuple[Any, ...]]:
        return [args for call, args in self.calls if call == name]

    def by_name(self, name: str) -> list[dict[str, Any]]:
        return [c for c in self.check_runs.values() if c["name"] == name]

    # -- API used by the app
    def create(self, name: str) -> dict[str, Any]:
        self.next_id += 1
        run = {"id": self.next_id, "name": name, "status": "queued", "conclusion": None, "output": {}}
        self.check_runs[self.next_id] = run
        self._record("create", name)
        return dict(run)

    def _update(self, check_ref: Any, **changes: Any) -> dict[str, Any]:
        run = self.check_runs.setdefault(int(check_ref), {"id": int(check_ref), "name": "?", "output": {}})
        output = changes.pop("output", None)
        run.update(changes)
        if output:
            run["output"] = output
        return dict(run)

    def queued(self, check_ref: Any, output: dict | None = None) -> dict[str, Any]:
        self._record("queued", check_ref, output)
        return self._update(check_ref, status="queued", output=output)

    def in_progress(self, check_ref: Any, output: dict | None = None) -> dict[str, Any]:
        self._record("in_progress", check_ref, output)
        return self._update(check_ref, status="in_progress", output=output)

    def _completed(self, name: str, check_ref: Any, output: dict | None) -> dict[str, Any] | None:
        if check_ref is None:
            return None
        self._record(name, check_ref, output)
        return self._update(check_ref, status="completed", conclusion=name, output=output)

    def success(self, check_ref: Any, output: dict | None = None) -> dict[str, Any] | None:
        return self._completed("success", check_ref, output)

    def failure(self, check_ref: Any, output: dict | None = None) -> dict[str, Any] | None:
        return self._completed("failure", check_ref, output)

    def cancelled(self, check_ref: Any, output: dict | None = None) -> dict[str, Any] | None:
        return self._completed("cancelled", check_ref, output)

    def skipped(self, check_ref: Any, output: dict | None = None) -> dict[str, Any] | None:
        return self._completed("skipped", check_ref, output)

    def get_check_run(self, check_ref: Any) -> dict[str, Any]:
        return dict(self.check_runs.get(int(check_ref), {"output": {"title": "t", "summary": "s"}}))

    def check_runs_for_ref(self, repo: str, sha: str, status: str = "queued") -> dict[str, Any]:
        self._record("check_runs_for_ref", repo, sha, status)
        return {"check_runs": self.listed_check_runs.get(status, [])}

    def fetch_username(self, github_id: Any) -> dict[str, Any] | None:
        return self.users.get(
            github_id, {"login": f"user{github_id}", "name": "User", "email": None, "type": "User", "company": "ACME"}
        )

    def pull_request_info(self, pr_id: int, repo: str) -> dict[str, Any]:
        return self.pr_info

    def fetch_pull_request_commits(self, pr_id: int, repo: str, page: int) -> list[dict[str, Any]]:
        return self.commits[page - 1] if page - 1 < len(self.commits) else []

    def pull_requests(self, repo: str, state: str = "open") -> list[dict[str, Any]]:
        return self.pulls

    def comment_reaction_thumb_up(self, repo: str, comment_id: int) -> dict[str, Any]:
        if self.fail_reactions:
            raise RuntimeError("reaction failed")
        self.reactions.append((repo, comment_id, "+1"))
        return {}

    def comment_reaction_thumb_down(self, repo: str, comment_id: int) -> dict[str, Any]:
        if self.fail_reactions:
            raise RuntimeError("reaction failed")
        self.reactions.append((repo, comment_id, "-1"))
        return {}

    def comment_reaction_rocket(self, repo: str, comment_id: int) -> dict[str, Any]:
        if self.fail_reactions:
            raise RuntimeError("reaction failed")
        self.reactions.append((repo, comment_id, "rocket"))
        return {"id": 4242, "content": "rocket"}

    def delete_comment_reaction(self, repo: str, comment_id: int, reaction_id: int) -> dict[str, Any]:
        if self.fail_reactions:
            raise RuntimeError("reaction failed")
        assert reaction_id == 4242, reaction_id
        self.reactions.remove((repo, comment_id, "rocket"))  # ValueError (like GitHub's 404) when already removed
        return {}

    def signature(self) -> str:
        return self.secret

    def installation_id(self) -> int:
        return 42


class FakeBamboo:
    def __init__(self) -> None:
        self.submit_status = 200
        self.submit_body: Any = {"buildResultKey": "PROJ-PLAN-1"}
        self.submit_text: str | None = None
        self.submissions: list[dict[str, Any]] = []
        self.comments: list[tuple[str | None, str]] = []
        self.jobs: dict[str | None, list[dict[str, str | None]]] = {}
        self.default_jobs: list[dict[str, str | None]] = []
        self.statuses: dict[str, dict[str, Any] | None] = {}
        self.results: dict[str, dict[str, Any] | None] = {}
        self.job_results: dict[str, dict[str, Any] | None] = {}
        self.stopped: list[str | None] = []
        self.restarted: list[str | None] = []
        self.cancel_comments: list[tuple[Any, Any]] = []
        self.logs: dict[str, str] = {}
        self.unreachable = False
        # Simulated stop: Bamboo reports a stopped result as finished after `stop_checks` state reads
        # (None: never, e.g. a hung agent). `events` records stop requests, state reads and submissions in order.
        self.stop_checks: int | None = 0
        self._reads: dict[str | None, int] = {}
        self.events: list[tuple[str, str | None]] = []

    def submit_pr_to_ci(self, check_suite: Any, plan: Any, ci_variables: list[dict[str, str]]) -> httpx.Response | None:
        self.events.append(("submit", check_suite.commit_sha_ref))
        self.submissions.append({"plan": plan.bamboo_ci_plan_name, "suite": check_suite.id, "variables": ci_variables})
        if self.unreachable:
            return None
        if self.submit_text is not None:
            return httpx.Response(self.submit_status, text=self.submit_text)
        return httpx.Response(self.submit_status, json=self.submit_body)

    def add_comment_to_ci(self, key: str | None, comment: str) -> httpx.Response:
        self.comments.append((key, comment))
        return httpx.Response(200)

    def running_plan(self, plan_key: str | None) -> list[dict[str, str | None]]:
        return self.jobs.get(plan_key, self.default_jobs)

    def get_status(self, ref: str) -> dict[str, Any] | None:
        return self.results.get(ref)

    def build_status(self, ref: str) -> dict[str, Any] | None:
        return self.statuses.get(ref)

    def result(self, job_key: str, expand: str = "") -> dict[str, Any] | None:
        return self.job_results.get(job_key)

    def build_log(self, url: str) -> str:
        return self.logs.get(url, "")

    def stop_plan(self, ref: str | None) -> None:
        self.stopped.append(ref)
        self.events.append(("stop", ref))

    def is_stopped(self, ref: str) -> bool:
        self.events.append(("check", ref))
        if self.stop_checks is None or ref not in self.stopped:
            return False
        self._reads[ref] = self._reads.get(ref, 0) + 1
        return self._reads[ref] > self.stop_checks

    def restart(self, plan_key: str | None) -> None:
        self.restarted.append(plan_key)

    def comment_cancelled(self, check_suite: Any, new_check_suite: Any) -> None:
        self.cancel_comments.append((check_suite.bamboo_ci_ref, new_check_suite.bamboo_ci_ref))


class FakeSlack:
    def __init__(self) -> None:
        self.events: list[tuple[str, Any]] = []
        self.group_reason: str | None = "partial rerun refused"
        self.user_ids: dict[str, str] = {}

    def _rec(self, name: str, arg: Any) -> None:
        self.events.append((name, getattr(arg, "id", arg)))

    def names(self) -> list[str]:
        return [name for name, _ in self.events]

    def execution_started_notification(self, check_suite: Any) -> None:
        self._rec("started", check_suite)

    def execution_finished_notification(self, check_suite: Any) -> None:
        self._rec("finished", check_suite)

    def stage_finished_notification(self, stage: Any) -> None:
        self._rec("stage_finished", stage)

    def stage_in_progress_notification(self, stage: Any) -> None:
        self._rec("stage_in_progress", stage)

    def notify_errors(self, job: Any) -> None:
        self._rec("errors", job)

    def notify_cancelled(self, job: Any) -> None:
        self._rec("cancelled", job)

    def notify_success(self, job: Any) -> None:
        self._rec("success", job)

    def invalid_rerun_group(self, stage: Any) -> str | None:
        self._rec("invalid_rerun_group", stage)
        return self.group_reason

    def invalid_rerun_dm(self, stage: Any, subscription: Any) -> None:
        self._rec("invalid_rerun_dm", subscription.slack_user_id)

    def find_user_id_by_name(self, name: str) -> str | None:
        return self.user_ids.get(name)
