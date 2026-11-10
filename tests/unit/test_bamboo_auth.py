#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_bamboo_auth.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from urllib.parse import parse_qs

import httpx
import pytest
from pydantic import SecretStr

from netdef_ci.clients.bamboo import BambooClient
from netdef_ci.clients.bamboo_auth import ServiceAccountAuth, response_summary, scope_set
from netdef_ci.helpers.config import Settings

BASE = "https://127.0.0.1"
TOKEN_URL = f"{BASE}/rest/oauth2/latest/token"


class FakeBamboo:
    """Token endpoint plus one API endpoint; the API accepts only the tokens listed in `valid`."""

    def __init__(self) -> None:
        self.issued = 0
        self.valid: set[str] = set()
        self.token_status = 200
        self.accept_tokens = True
        self.token_forms: list[dict[str, list[str]]] = []
        self.api_auth: list[str | None] = []
        self.granted = "WRITE"
        self.refusal = httpx.Response(401)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_URL:
            self.token_forms.append(parse_qs(request.content.decode()))
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_client"})
            self.issued += 1
            token = f"tok-{self.issued}"
            self.valid.add(token)
            return httpx.Response(
                200, json={"access_token": token, "token_type": "bearer", "expires_in": 3600, "scope": self.granted}
            )
        auth = request.headers.get("authorization")
        self.api_auth.append(auth)
        if not self.accept_tokens or auth is None or auth.removeprefix("Bearer ") not in self.valid:
            return self.refusal
        return httpx.Response(200, json={"ok": True})


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def bamboo() -> FakeBamboo:
    return FakeBamboo()


def http(bamboo: FakeBamboo, auth: httpx.Auth) -> httpx.Client:
    return httpx.Client(base_url=BASE, transport=httpx.MockTransport(bamboo), auth=auth)


def test_token_is_fetched_once_and_reused(bamboo) -> None:
    auth = ServiceAccountAuth(BASE, "cid", "csecret", scope="WRITE")
    client = http(bamboo, auth)
    assert client.get("/rest/api/latest/info").status_code == 200
    assert client.post("/rest/api/latest/queue/PROJ-PLAN", content=b"x").status_code == 200
    assert bamboo.issued == 1 and bamboo.api_auth == ["Bearer tok-1", "Bearer tok-1"]
    assert bamboo.token_forms == [
        {"grant_type": ["client_credentials"], "client_id": ["cid"], "client_secret": ["csecret"], "scope": ["WRITE"]}
    ]
    assert auth.granted_scope == "WRITE" and auth.last_error is None


def test_scope_is_not_sent_when_empty(bamboo) -> None:
    http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret")).get("/rest/api/latest/info")
    assert "scope" not in bamboo.token_forms[0]


def test_token_is_renewed_before_it_expires(bamboo) -> None:
    clock = Clock()
    client = http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret", clock=clock))
    client.get("/rest/api/latest/info")
    clock.now += 3600 - 61
    client.get("/rest/api/latest/info")
    assert bamboo.issued == 1
    clock.now += 2  # inside the refresh margin
    client.get("/rest/api/latest/info")
    assert bamboo.issued == 2 and bamboo.api_auth[-1] == "Bearer tok-2"


def test_rejected_cached_token_is_replaced_and_the_request_sent_once_more(bamboo) -> None:
    client = http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret"))
    client.get("/rest/api/latest/info")
    bamboo.valid.clear()  # e.g. revoked in Bamboo
    response = client.put("/rest/api/latest/queue/PROJ-PLAN-1", content=b"<x/>")
    assert response.status_code == 200
    assert bamboo.issued == 2 and bamboo.api_auth[-2:] == ["Bearer tok-1", "Bearer tok-2"]


def test_fresh_token_rejected_is_not_retried(bamboo) -> None:
    bamboo.accept_tokens = False  # e.g. the service account lacks permission: no loop of new tokens
    assert http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret")).get("/rest/api/latest/info").status_code == 401
    assert bamboo.issued == 1 and bamboo.api_auth == ["Bearer tok-1"]


def test_failed_token_request_sends_the_call_without_credentials(bamboo, caplog) -> None:
    bamboo.token_status = 401
    auth = ServiceAccountAuth(BASE, "cid", "csecret")
    assert http(bamboo, auth).get("/rest/api/latest/info").status_code == 401
    assert bamboo.api_auth == [None]
    assert auth.last_error is not None and auth.last_error.startswith("HTTP 401")
    assert "csecret" not in auth.last_error and "csecret" not in caplog.text


def test_service_account_wins_over_token_and_basic(bamboo, settings, monkeypatch) -> None:
    monkeypatch.setattr(settings, "bamboo_token", SecretStr("pat"))
    monkeypatch.setattr(settings, "bamboo_client_id", "cid")
    monkeypatch.setattr(settings, "bamboo_client_secret", SecretStr("csecret"))
    client = BambooClient(settings, transport=httpx.MockTransport(bamboo))
    assert client.get_json("/rest/api/latest/info") == {"ok": True}
    assert bamboo.api_auth == ["Bearer tok-1"]


def test_incomplete_service_account_falls_back(settings: Settings, monkeypatch) -> None:
    monkeypatch.setattr(settings, "bamboo_client_id", "cid")
    monkeypatch.setattr(settings, "bamboo_client_secret", None)
    assert settings.bamboo_service_account() is None and settings.bamboo_service_account_incomplete()
    assert BambooClient(settings).service_account is None


TOMCAT_401 = (
    '<!doctype html><html lang="en"><head><title>HTTP Status 401 &ndash; Unauthorized</title><style type="text/css">'
    "body {font-family:Tahoma,Arial,sans-serif;}</style></head><body><h1>HTTP Status 401</h1></body></html>"
)


def test_response_summary_reads_json_messages_and_html_titles() -> None:
    scope_403 = {"message": "Client must have sufficient scopes to access this resource. Required scopes: [TRIGGER]"}
    assert response_summary(httpx.Response(403, json=scope_403)).endswith("Required scopes: [TRIGGER]")
    oauth = {"error": "invalid_request", "error_description": "The provided authorization data is invalid"}
    assert response_summary(httpx.Response(400, json=oauth)) == "The provided authorization data is invalid"
    assert response_summary(httpx.Response(401, text=TOMCAT_401)) == "HTML page: HTTP Status 401 \u2013 Unauthorized"
    assert response_summary(httpx.Response(401, text="")) == "(empty body)"


def test_scope_set_accepts_spaces_and_commas() -> None:
    assert scope_set("READ TRIGGER,WRITE") == {"READ", "TRIGGER", "WRITE"} and scope_set(None) == set()


def test_token_log_names_requested_and_granted_scopes_and_warns_about_missing_ones(bamboo, caplog) -> None:
    bamboo.granted = "TRIGGER WRITE"
    http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret", scope="READ TRIGGER WRITE")).get("/rest/api/latest/info")
    assert "token obtained (requested scope: READ TRIGGER WRITE; granted scope: TRIGGER WRITE" in caplog.text
    assert "did not grant the scopes READ" in caplog.text
    assert "tok-1" not in caplog.text


def test_refused_token_is_logged_with_path_scopes_origin_and_reason(bamboo, caplog) -> None:
    bamboo.accept_tokens = False
    bamboo.refusal = httpx.Response(401, text=TOMCAT_401)
    auth = ServiceAccountAuth(BASE, "cid", "csecret", scope="READ TRIGGER WRITE")
    http(bamboo, auth).post("/rest/api/latest/queue/PROJ-PLAN", content=b"x")
    assert (
        "Bamboo answered HTTP 401 to POST /rest/api/latest/queue/PROJ-PLAN with the service account token (new; "
        "requested scope: READ TRIGGER WRITE; granted scope: WRITE): HTML page: HTTP Status 401" in caplog.text
    )


def test_missing_scope_403_is_logged_after_a_renewal(bamboo, caplog) -> None:
    client = http(bamboo, ServiceAccountAuth(BASE, "cid", "csecret", scope="WRITE"))
    client.get("/rest/api/latest/info")
    bamboo.valid.clear()
    bamboo.accept_tokens = False
    bamboo.refusal = httpx.Response(403, json={"message": "Required scopes: [TRIGGER]"})
    assert client.post("/rest/api/latest/queue/PROJ-PLAN", content=b"x").status_code == 403
    assert "HTTP 403 to POST /rest/api/latest/queue/PROJ-PLAN" in caplog.text
    assert "(renewed after a 401; requested scope: WRITE" not in caplog.text  # the cached token got a 403, not a 401
    assert "(cached; requested scope: WRITE; granted scope: WRITE): Required scopes: [TRIGGER]" in caplog.text


class SessionCookieBamboo(FakeBamboo):
    """Bamboo/Tomcat as seen on ci2: every answer sets a JSESSIONID, and a request that sends that session back next
    to a Bearer token gets Tomcat's HTML 401."""

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) != TOKEN_URL and "cookie" in request.headers:
            self.api_auth.append(request.headers.get("authorization"))
            return httpx.Response(401, text=TOMCAT_401)
        response = super().__call__(request)
        response.headers["set-cookie"] = "JSESSIONID=abc123; Path=/; Secure; HttpOnly"
        return response


@pytest.mark.parametrize("mode", ["service_account", "personal_token"])
def test_token_clients_keep_no_session_cookie(settings, monkeypatch, mode) -> None:
    bamboo = SessionCookieBamboo()
    if mode == "service_account":
        monkeypatch.setattr(settings, "bamboo_client_id", "cid")
        monkeypatch.setattr(settings, "bamboo_client_secret", SecretStr("csecret"))
    else:
        bamboo.valid.add("pat")
        monkeypatch.setattr(settings, "bamboo_token", SecretStr("pat"))
    client = BambooClient(settings, transport=httpx.MockTransport(bamboo))
    for _ in range(3):  # queue, comment, result polling: only the first one used to succeed
        assert client.get_json("/rest/api/latest/info") == {"ok": True}
    assert bamboo.issued == (1 if mode == "service_account" else 0)
