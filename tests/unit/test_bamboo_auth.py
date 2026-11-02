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
from netdef_ci.clients.bamboo_auth import ServiceAccountAuth
from netdef_ci.config import Settings

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

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_URL:
            self.token_forms.append(parse_qs(request.content.decode()))
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_client"})
            self.issued += 1
            token = f"tok-{self.issued}"
            self.valid.add(token)
            return httpx.Response(
                200, json={"access_token": token, "token_type": "bearer", "expires_in": 3600, "scope": "WRITE"}
            )
        auth = request.headers.get("authorization")
        self.api_auth.append(auth)
        if not self.accept_tokens or auth is None or auth.removeprefix("Bearer ") not in self.valid:
            return httpx.Response(401)
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
