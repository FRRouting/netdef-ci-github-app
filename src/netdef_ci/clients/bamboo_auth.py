#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/bamboo_auth.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Bamboo 12 service account authentication: OAuth 2.0 client credentials (2LO) with a cached Bearer token."""

from __future__ import annotations

import html
import re
import threading
import time
from collections.abc import Callable, Generator

import httpx

from netdef_ci.helpers.logs import Log

TOKEN_PATH = "/rest/oauth2/latest/token"
# A token is replaced this long before Bamboo says it expires, so a request never leaves with an expired one.
TOKEN_REFRESH_MARGIN_SECONDS = 60.0
DEFAULT_TOKEN_LIFETIME_SECONDS = 3600.0
_HTML_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def response_summary(response: httpx.Response, limit: int = 300) -> str:
    """Short, readable reason from a Bamboo answer: the JSON `message`/`error_description`, the `<title>` of an HTML
    error page (Tomcat answers a rejected token with one), or the start of the body."""
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        for key in ("message", "error_description", "error"):
            value = body.get(key)
            if isinstance(value, str) and value:
                return value[:limit]
    text = response.text
    match = _HTML_TITLE.search(text)
    if match:
        return f"HTML page: {html.unescape(match.group(1)).strip()}"[:limit]
    return " ".join(text.split())[:limit] or "(empty body)"


def scope_set(scope: str | None) -> set[str]:
    """Scopes of an OAuth `scope` string; Bamboo may separate them with spaces or commas."""
    return {part for part in re.split(r"[\s,]+", scope or "") if part}


class ServiceAccountAuth(httpx.Auth):
    """Gets a token from `/rest/oauth2/latest/token`, keeps it until shortly before it expires and, when Bamboo
    answers 401 to a cached token (revoked, Bamboo restarted), gets a new one and sends the request once more.
    A failed token request is logged and the request goes out without credentials, so callers see Bamboo's 401."""

    requires_response_body = True  # the token response must be read inside the flow

    def __init__(
        self,
        base_url: str,
        client_id: str,
        client_secret: str,
        scope: str | None = None,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.token_url = base_url.rstrip("/") + TOKEN_PATH
        self._client_id = client_id
        self._client_secret = client_secret
        self._scope = scope
        self._clock = clock
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at = 0.0
        self.granted_scope: str | None = None
        self.last_error: str | None = None
        self.token_fetches = 0
        self.log = Log("bamboo")

    def auth_flow(self, request: httpx.Request) -> Generator[httpx.Request, httpx.Response]:
        token = self._cached_token()
        origin = "cached"
        if token is None:
            token = yield from self._fetch_token()
            origin = "new"
        self._authorize(request, token)
        response = yield request
        if response.status_code == 401 and origin == "cached":
            self._forget(token)
            token = yield from self._fetch_token()
            if token is None:
                return
            origin = "renewed after a 401"
            self._authorize(request, token)
            response = yield request
        if response.status_code in (401, 403) and token is not None:
            self._log_refusal(request, response, origin)

    def _log_refusal(self, request: httpx.Request, response: httpx.Response, origin: str) -> None:
        """Everything needed to tell a missing scope, a missing project permission and a rejected token apart."""
        self.log.error(
            "Bamboo answered HTTP %s to %s %s with the service account token (%s; requested scope: %s; granted "
            "scope: %s): %s",
            response.status_code,
            request.method,
            request.url.path,
            origin,
            self._scope or "-",
            self.granted_scope or "-",
            response_summary(response),
        )

    @staticmethod
    def _authorize(request: httpx.Request, token: str | None) -> None:
        if token is not None:
            request.headers["Authorization"] = f"Bearer {token}"

    def _cached_token(self) -> str | None:
        with self._lock:
            return self._token if self._token is not None and self._clock() < self._expires_at else None

    def _forget(self, token: str | None) -> None:
        with self._lock:
            if self._token == token:
                self._token = None

    def _fetch_token(self) -> Generator[httpx.Request, httpx.Response, str | None]:
        data = {"grant_type": "client_credentials", "client_id": self._client_id, "client_secret": self._client_secret}
        if self._scope:
            data["scope"] = self._scope
        response = yield httpx.Request("POST", self.token_url, data=data, headers={"Accept": "application/json"})
        try:
            body = response.json() if response.is_success else {}
        except ValueError:
            body = {}
        token = body.get("access_token") if isinstance(body, dict) else None
        if not isinstance(token, str) or not token:
            # The body is Bamboo's error description (it never carries the secret, which only goes in the request).
            self.last_error = f"HTTP {response.status_code} {response_summary(response, 200)}"
            self.log.error(
                "Bamboo service account token request failed (requested scope: %s): %s",
                self._scope or "-",
                self.last_error,
            )
            return None
        try:
            lifetime = float(body.get("expires_in") or DEFAULT_TOKEN_LIFETIME_SECONDS)
        except (TypeError, ValueError):
            lifetime = DEFAULT_TOKEN_LIFETIME_SECONDS
        with self._lock:
            self._token = token
            self._expires_at = self._clock() + max(lifetime - TOKEN_REFRESH_MARGIN_SECONDS, 0.0)
        self.granted_scope = body.get("scope") if isinstance(body.get("scope"), str) else None
        self.last_error = None
        self.token_fetches += 1
        self.log.info(
            "Bamboo service account token obtained (requested scope: %s; granted scope: %s; expires in %ss)",
            self._scope or "-",
            self.granted_scope or "-",
            int(lifetime),
        )
        missing = scope_set(self._scope) - scope_set(self.granted_scope) if self.granted_scope is not None else set()
        if missing:
            self.log.warning(
                "Bamboo did not grant the scopes %s: add them to the service account credential",
                " ".join(sorted(missing)),
            )
        return token
