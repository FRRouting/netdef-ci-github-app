#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/github.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""GitHub App client: JWT authentication, cached/renewed installation tokens and the Checks/Issues API calls used by
the CI (port of lib/github/check.rb)."""

from __future__ import annotations

import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import jwt

from netdef_ci import metrics
from netdef_ci.clients.http import Sleeper, request_with_retries
from netdef_ci.config import GitHubAppConfig, Settings
from netdef_ci.logs import Log, PullRequestAdapter, github_http_logger

Json = dict[str, Any]
TOKEN_REFRESH_MARGIN = timedelta(minutes=5)
JWT_LIFETIME_SECONDS = 9 * 60
MAX_SUMMARY = 65_535


class GithubError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"GitHub API error {status}: {message}")
        self.status = status


class GithubNotFound(GithubError):
    pass


class GithubAuthError(Exception):
    pass


class GithubUpdateMismatch(Exception):
    """GitHub answered the update with a conclusion different from the requested one."""


class AppAuth:
    """Authenticates one GitHub App: signs the JWT and keeps the installation access token fresh."""

    def __init__(
        self, config: GitHubAppConfig, settings: Settings, client: httpx.Client, sleep: Sleeper = time.sleep
    ) -> None:
        self.config = config
        self.settings = settings
        self._client = client
        self._sleep = sleep
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at: datetime | None = None
        self._installation_id: int | None = None
        self._private_key: bytes | None = None

    def app_jwt(self) -> str:
        if self._private_key is None:
            self._private_key = Path(self.config.cert).read_bytes()
        now = int(time.time())
        # iat is backdated 60 s to tolerate clock drift; exp - iat stays within GitHub's 10 minute limit.
        payload = {"iat": now - 60, "exp": now + JWT_LIFETIME_SECONDS, "iss": self.config.login}
        return jwt.encode(payload, self._private_key, algorithm="RS256")

    def _call(self, method: str, path: str, http_log: PullRequestAdapter | None, **kwargs: Any) -> httpx.Response:
        headers = {"Authorization": f"Bearer {self.app_jwt()}", **_base_headers()}
        return request_with_retries(
            self._client,
            method,
            f"{self.settings.github_api_url}{path}",
            max_retries=self.settings.github_max_retries,
            sleep=self._sleep,
            logger=http_log or github_http_logger(),
            headers=headers,
            **kwargs,
        )

    def installation_id(self, http_log: PullRequestAdapter | None = None) -> int:
        if self._installation_id is None:
            response = self._call("GET", "/app/installations", http_log)
            _raise_for_status(response)
            installations = response.json()
            self._installation_id = int(installations[0]["id"]) if installations else 0
        return self._installation_id

    def token(self, http_log: PullRequestAdapter | None = None) -> str | None:
        """Installation token (None when the App has no installation); renewed 5 minutes before expiry. `http_log`
        tags the token calls with the pull request whose request needed them."""
        with self._lock:
            now = datetime.now(UTC)
            if self._token and self._expires_at and now < self._expires_at - TOKEN_REFRESH_MARGIN:
                return self._token
            installation = self.installation_id(http_log)
            if installation == 0:
                return None
            response = self._call("POST", f"/app/installations/{installation}/access_tokens", http_log)
            _raise_for_status(response)
            data = response.json()
            self._token = data["token"]
            self._expires_at = (
                datetime.fromisoformat(data["expires_at"].replace("Z", "+00:00"))
                if data.get("expires_at")
                else now + timedelta(minutes=55)
            )
            return self._token

    def invalidate(self) -> None:
        with self._lock:
            self._token = None
            self._expires_at = None
            self._installation_id = None


_registry: dict[tuple[str, str], AppAuth] = {}
_registry_lock = threading.Lock()


def get_app_auth(
    config: GitHubAppConfig, settings: Settings, client: httpx.Client, sleep: Sleeper = time.sleep
) -> AppAuth:
    key = (config.login, config.cert)
    with _registry_lock:
        if key not in _registry:
            _registry[key] = AppAuth(config, settings, client, sleep)
        return _registry[key]


def reset_app_auth_registry() -> None:
    with _registry_lock:
        _registry.clear()


def _base_headers() -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "netdef-ci-github-app",
    }


def _raise_for_status(response: httpx.Response) -> None:
    if response.status_code < 400:
        return
    message = response.text[:300]
    metrics.GITHUB_API_REQUESTS.labels(method=response.request.method, status=f"{response.status_code // 100}xx").inc()
    if response.status_code == 404:
        raise GithubNotFound(404, message)
    raise GithubError(response.status_code, message)


class GithubCheck:
    """Equivalent of `Github::Check`: authenticated by repository, falling back to the first working App."""

    def __init__(
        self,
        check_suite: Any | None,
        settings: Settings,
        *,
        client: httpx.Client | None = None,
        sleep: Sleeper = time.sleep,
    ) -> None:
        self.check_suite = check_suite
        self.settings = settings
        self.log = Log("github_check_api")
        self._sleep = sleep
        self._client = client or httpx.Client(timeout=settings.http_timeout_seconds)
        self._auth: AppAuth | None = None
        self._pr_id: int | None = getattr(getattr(check_suite, "pull_request", None), "github_pr_id", None)
        self._authenticate()

    # ------------------------------------------------------------------ authentication
    @property
    def repository(self) -> str | None:
        pull_request = getattr(self.check_suite, "pull_request", None)
        return getattr(pull_request, "repository", None)

    def _authenticate(self) -> None:
        apps = self.settings.github_apps()
        by_repo = [a for a in apps if a.repo and a.repo == self.repository]
        candidates = by_repo + [a for a in apps if a not in by_repo]
        for config in candidates:
            try:
                auth = get_app_auth(config, self.settings, self._client, self._sleep)
                if auth.token(github_http_logger(self._pr_id)) is not None:
                    self._auth = auth
                    return
            except Exception as error:
                self.log.error(
                    "GitHub App %s could not authenticate: %s: %s", config.login, type(error).__name__, error
                )
        raise GithubAuthError("Github Authentication Failed")

    # ------------------------------------------------------------------ transport
    def _request(self, method: str, path: str, *, pr_id: int | None = None, **kwargs: Any) -> Any:
        """`pr_id` overrides the check suite's pull request in `github_http.log` (calls that name a pull request)."""
        assert self._auth is not None
        http_log = github_http_logger(pr_id if pr_id is not None else self._pr_id)
        for attempt in (0, 1):
            token = self._auth.token(http_log)
            headers = {"Authorization": f"Bearer {token}", **_base_headers()}
            response = request_with_retries(
                self._client,
                method,
                f"{self.settings.github_api_url}{path}",
                max_retries=self.settings.github_max_retries,
                sleep=self._sleep,
                logger=http_log,
                headers=headers,
                **kwargs,
            )
            if response.status_code == 401 and attempt == 0:
                self._auth.invalidate()  # expired/revoked installation token: renew once
                continue
            metrics.GITHUB_API_REQUESTS.labels(method=method, status=f"{response.status_code // 100}xx").inc()
            if response.status_code >= 400:
                message = response.text[:300]
                if response.status_code == 404:
                    raise GithubNotFound(404, message)
                raise GithubError(response.status_code, message)
            return response.json() if response.content else {}
        raise GithubError(401, "unauthorized")  # pragma: no cover

    # ------------------------------------------------------------------ reads
    def pull_request_info(self, pr_id: int, repo: str) -> Json:
        return self._request("GET", f"/repos/{repo}/pulls/{pr_id}", pr_id=pr_id)

    def fetch_pull_request_commits(self, pr_id: int, repo: str, page: int) -> list[Json]:
        return self._request(
            "GET", f"/repos/{repo}/pulls/{pr_id}/commits", pr_id=pr_id, params={"per_page": 100, "page": page}
        )

    def pull_requests(self, repo: str, state: str = "open") -> list[Json]:
        return self._request("GET", f"/repos/{repo}/pulls", params={"state": state, "per_page": 100})

    def check_runs_for_ref(self, repo: str, sha: str, status: str = "queued") -> Json:
        return self._request(
            "GET", f"/repos/{repo}/commits/{sha}/check-runs", params={"status": status, "per_page": 100}
        )

    def get_check_run(self, check_ref: str | int) -> Json:
        return self._request("GET", f"/repos/{self._repo()}/check-runs/{check_ref}")

    def fetch_username(self, github_id: int | str) -> Json | None:
        try:
            # Octokit semantics: integers are account ids (`/user/:id`), strings are logins (`/users/:login`).
            path = f"/user/{github_id}" if isinstance(github_id, int) else f"/users/{github_id}"
            return self._request("GET", path)
        except Exception:
            return None

    def installation_id(self) -> int:
        assert self._auth is not None
        return self._auth.installation_id(github_http_logger(self._pr_id))

    def signature(self) -> str:
        return self.settings.webhook_secret.get_secret_value()

    # ------------------------------------------------------------------ writes
    def add_comment(self, pr_id: int, comment: str, repo: str) -> Json:
        return self._request("POST", f"/repos/{repo}/issues/{pr_id}/comments", pr_id=pr_id, json={"body": comment})

    def comment_reaction_thumb_up(self, repo: str, comment_id: int) -> Json:
        return self._request("POST", f"/repos/{repo}/issues/comments/{comment_id}/reactions", json={"content": "+1"})

    def comment_reaction_thumb_down(self, repo: str, comment_id: int) -> Json:
        return self._request("POST", f"/repos/{repo}/issues/comments/{comment_id}/reactions", json={"content": "-1"})

    def comment_reaction_rocket(self, repo: str, comment_id: int) -> Json:
        return self._request(
            "POST", f"/repos/{repo}/issues/comments/{comment_id}/reactions", json={"content": "rocket"}
        )

    def delete_comment_reaction(self, repo: str, comment_id: int, reaction_id: int) -> Json:
        return self._request("DELETE", f"/repos/{repo}/issues/comments/{comment_id}/reactions/{reaction_id}")

    def create(self, name: str) -> Json:
        if self.check_suite is None:
            raise GithubError(0, "cannot create a check run without a check suite")
        return self._request(
            "POST",
            f"/repos/{self._repo()}/check-runs",
            json={"name": name, "head_sha": self.check_suite.commit_sha_ref},
        )

    def queued(self, check_ref: str | int, output: dict[str, str] | None = None) -> Json:
        return self._basic_status(check_ref, "queued", output)

    def in_progress(self, check_ref: str | int, output: dict[str, str] | None = None) -> Json:
        return self._basic_status(check_ref, "in_progress", output)

    def cancelled(self, check_ref: str | int | None, output: dict[str, str] | None = None) -> Json | None:
        return self._completed(check_ref, "cancelled", output)

    def success(self, check_ref: str | int | None, output: dict[str, str] | None = None) -> Json | None:
        return self._completed(check_ref, "success", output)

    def failure(self, check_ref: str | int | None, output: dict[str, str] | None = None) -> Json | None:
        return self._completed(check_ref, "failure", output)

    def skipped(self, check_ref: str | int | None, output: dict[str, str] | None = None) -> Json | None:
        return self._completed(check_ref, "skipped", output)

    # ------------------------------------------------------------------ internals
    def _repo(self) -> str:
        repo = self.repository
        if repo is None:
            raise GithubError(0, "check suite without pull request/repository")
        return repo

    @staticmethod
    def _output(output: dict[str, str] | None) -> dict[str, str] | None:
        if not output:
            return None
        clean = dict(output)
        if len(clean.get("summary", "")) > MAX_SUMMARY:
            clean["summary"] = clean["summary"][:MAX_SUMMARY]  # GitHub rejects larger summaries (422)
        return clean

    def _patch(self, check_ref: str | int, options: Json) -> Json:
        return self._request("PATCH", f"/repos/{self._repo()}/check-runs/{int(check_ref)}", json=options)

    def _basic_status(self, check_ref: str | int, status: str, output: dict[str, str] | None) -> Json:
        options: Json = {"status": status}
        if (clean := self._output(output)) is not None:
            options["output"] = clean
        response = self._patch(check_ref, options)
        self.log.info("basic_status: %s, status: %s", check_ref, status)
        return response

    def _completed(self, check_ref: str | int | None, conclusion: str, output: dict[str, str] | None) -> Json | None:
        if check_ref is None:
            return None
        options: Json = {"status": "completed", "conclusion": conclusion}
        if (clean := self._output(output)) is not None:
            options["output"] = clean
        retries = 0
        while True:
            try:
                response = self._patch(check_ref, options)
                if response.get("conclusion") != conclusion:
                    raise GithubUpdateMismatch("GitHub failed to update status")
                self.log.info("completed: %s, conclusion: %s", check_ref, conclusion)
                return response
            except GithubNotFound, GithubUpdateMismatch:
                # The check run may not be visible yet (eventual consistency): bounded retries, 5 s steps.
                retries += 1
                self._sleep(retries * 5)
                if retries <= 3:
                    continue
                self.log.error("%s not found at GitHub", check_ref)
                return {}
