#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/bamboo.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Bamboo CI REST client (port of lib/bamboo_ci/*.rb and the `GitHubApp::Request` helper)."""

from __future__ import annotations

import time
from typing import Any
from xml.sax.saxutils import escape

import httpx

from netdef_ci import metrics
from netdef_ci.clients.http import Sleeper
from netdef_ci.config import Settings
from netdef_ci.logs import Log

JsonDict = dict[str, Any]


class BambooClient:
    def __init__(
        self, settings: Settings, *, transport: httpx.BaseTransport | None = None, sleep: Sleeper = time.sleep
    ) -> None:
        self.settings = settings
        self._sleep = sleep
        credentials = settings.bamboo_credentials()
        self._auth = (credentials.username, credentials.password) if credentials else None
        self._client = httpx.Client(
            base_url=settings.bamboo_base_url,
            verify=settings.bamboo_verify_tls,
            timeout=settings.http_timeout_seconds,
            transport=transport,
            follow_redirects=False,
        )
        self.log = Log("bamboo")

    # ---------------------------------------------------------------- low level
    def _send(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        headers = dict(kwargs.pop("headers", {}))
        return self._client.request(method, url, auth=self._auth, headers=headers, **kwargs)  # type: ignore[arg-type]

    def get_json(self, url: str, params: dict[str, str] | None = None) -> JsonDict | None:
        """GET returning parsed JSON, or None on any failure (network, non-JSON body)."""
        try:
            response = self._send("GET", url, params=params, headers={"Accept": "application/json"})
            data = response.json()
        except Exception as error:
            self.log.error("HTTP GET Request failed (%s: %s) for %s", type(error).__name__, error, url)
            return None
        return data if isinstance(data, dict) else None

    def _write(
        self, method: str, url: str, body: str | None = None, params: dict[str, str] | None = None
    ) -> httpx.Response | None:
        headers = {"Accept": "application/json"}
        content = None
        if body is not None:
            headers["Content-Type"] = "application/xml"
            content = body.encode()
        elif method == "PUT":
            headers["Content-Type"] = "application/xml"
        try:
            return self._send(method, url, params=params, headers=headers, content=content)
        except Exception as error:
            self.log.error("HTTP %s Request failed (%s: %s) for %s", method, type(error).__name__, error, url)
            return None

    # ---------------------------------------------------------------- api (lib/bamboo_ci/api.rb)
    def fetch_executions(self, plan: str) -> JsonDict | None:
        return metrics.track_bamboo("fetch_executions", lambda: self.get_json(f"/rest/api/latest/search/jobs/{plan}"))

    def get_status(self, ref: str) -> JsonDict | None:
        return metrics.track_bamboo(
            "get_status",
            lambda: self.get_json(f"/rest/api/latest/result/{ref}", {"expand": "stages.stage.results,artifacts"}),
        )

    def build_status(self, ref: str) -> JsonDict | None:
        return self.get_json(f"/rest/api/latest/result/status/{ref}")

    def submit_pr_to_ci(self, check_suite: Any, plan: Any, ci_variables: list[dict[str, str]]) -> httpx.Response | None:
        pr = check_suite.pull_request
        params = {
            "customRevision": check_suite.merge_branch or "",
            "bamboo.variable.github_repo": pr.repository,
            "bamboo.variable.github_pullreq": str(pr.github_pr_id),
            "bamboo.variable.github_branch": check_suite.merge_branch or "",
            "bamboo.variable.github_merge_sha": check_suite.commit_sha_ref,
            "bamboo.variable.github_base_sha": check_suite.base_sha_ref,
        }
        for variable in ci_variables:
            params[f"bamboo.variable.github_{variable['name']}"] = variable["value"]
        self.log.debug("Submitting plan %s (variables: %s)", plan.bamboo_ci_plan_name, sorted(params))
        return metrics.track_bamboo(
            "submit_plan",
            lambda: self._write("POST", f"/rest/api/latest/queue/{plan.bamboo_ci_plan_name}", params=params),
        )

    def add_comment_to_ci(self, key: str | None, comment: str) -> httpx.Response | None:
        body = f"<comment><content>{escape(comment)}</content></comment>"
        return metrics.track_bamboo(
            "add_comment", lambda: self._write("POST", f"/rest/api/latest/result/{key}/comment", body)
        )

    # ---------------------------------------------------------------- running plan / result / retry / stop / download
    def running_plan(self, plan_key: str | None) -> list[dict[str, str | None]]:
        """Jobs of a running plan: [{name, job_ref, stage}] (lib/bamboo_ci/running_plan.rb)."""
        resp = self.get_json(f"/rest/api/latest/result/{plan_key}", {"expand": "stages.stage.results"})
        stages = (resp or {}).get("stages", {}).get("stage") if resp else None
        if not stages:
            return []
        jobs: list[dict[str, str | None]] = []
        for stage in stages:
            for job in (stage.get("results") or {}).get("result") or []:
                jobs.append(
                    {
                        "name": (job.get("plan") or {}).get("shortName"),
                        "job_ref": job.get("key"),
                        "stage": job.get("stage"),
                    }
                )
        return jobs

    def result(self, job_key: str, expand: str = "testResults.failedTests.testResult.errors") -> JsonDict | None:
        return self.get_json(f"/rest/api/latest/result/{job_key}", {"expand": expand})

    def restart(self, plan_key: str | None) -> httpx.Response | None:
        return metrics.track_bamboo(
            "retry_plan",
            lambda: self._write("PUT", f"/rest/api/latest/queue/{plan_key}", params={"executeAllStages": "true"}),
        )

    def rerun(self, plan_key: str | None) -> str | None:
        resp = metrics.track_bamboo(
            "rerun_plan",
            lambda: self._write(
                "PUT",
                f"/rest/api/latest/queue/{plan_key}",
                params={"executeAllStages": "true", "orphanRemoval": "true"},
            ),
        )
        return resp.text if resp is not None else None

    def stop_job(self, job_key: str) -> httpx.Response | None:
        return metrics.track_bamboo("stop_job", lambda: self._write("DELETE", f"/rest/api/latest/queue/{job_key}"))

    def stop_plan(self, bamboo_ci_ref: str | None) -> httpx.Response | None:
        def call() -> httpx.Response | None:
            try:
                return self._send(
                    "GET",
                    "/build/admin/stopPlan.action",
                    params={"planResultKey": str(bamboo_ci_ref)},
                    headers={"Accept": "application/json"},
                )
            except Exception as error:
                self.log.error("stop_plan failed (%s: %s) for %s", type(error).__name__, error, bamboo_ci_ref)
                return None

        return metrics.track_bamboo("stop_plan", call)

    def is_stopped(self, bamboo_ci_ref: str) -> bool:
        """True only when Bamboo reports the result as no longer active (`Finished`/`NotBuilt`) or no longer knows
        it (404). Running, queued, unknown states and errors are False."""

        def call() -> bool:
            try:
                response = self._send(
                    "GET", f"/rest/api/latest/result/{bamboo_ci_ref}", headers={"Accept": "application/json"}
                )
            except Exception as error:
                self.log.error("is_stopped failed (%s: %s) for %s", type(error).__name__, error, bamboo_ci_ref)
                return False
            if response.status_code == 404:
                return True
            if response.status_code != 200:
                return False
            try:
                data = response.json()
            except ValueError:
                return False
            state = str(data.get("lifeCycleState") or "") if isinstance(data, dict) else ""
            return state in ("Finished", "NotBuilt")

        return bool(metrics.track_bamboo("result_state", call))

    def comment_cancelled(self, check_suite: Any, new_check_suite: Any) -> None:
        new_url = f"https://{self.settings.ci_url}/browse/{new_check_suite.bamboo_ci_ref}"
        comment = f"This execution was cancelled due to a new commit or `ci:rerun` ({new_url})"
        self.add_comment_to_ci(check_suite.bamboo_ci_ref, comment)

    def download(self, url: str) -> str | None:
        try:
            return self._send("GET", url).text
        except Exception as error:
            self.log.error("Download failed (%s: %s) for %s", type(error).__name__, error, url)
            return None

    def build_log(self, url: str) -> str:
        """Last 10 lines of a build log; up to 4 attempts, 5 s apart (BambooCi::Download.build_log)."""
        for attempt in range(4):
            body = self.download(url)
            if body:
                return "\n".join(body.split("\n")[-10:])
            if attempt < 3:
                self._sleep(5)
        return ""

    def close(self) -> None:
        self._client.close()
