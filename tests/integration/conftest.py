#  SPDX-License-Identifier: BSD-2-Clause
#
#  conftest.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import base64
import json
from collections.abc import Callable
from typing import Any

import pytest
from fastapi.testclient import TestClient

from netdef_ci.security import compute_signature
from netdef_ci.web.app import create_app


class Api:
    """Thin client that signs requests like GitHub / Bamboo do (HMAC-SHA256 over the raw body)."""

    secret = "test-secret"

    def __init__(self) -> None:
        self.http = TestClient(create_app(init_database=False), raise_server_exceptions=False)

    @staticmethod
    def raw(payload: Any) -> bytes:
        return payload if isinstance(payload, bytes) else json.dumps(payload).encode()

    def signed(self, body: bytes, header: str = "X-Hub-Signature-256") -> dict[str, str]:
        return {header: compute_signature(self.secret, body), "Content-Type": "application/json"}

    def github(self, event: str | None, payload: Any, path: str = "/", **headers: str):
        body = self.raw(payload)
        sent = {**self.signed(body), **headers}
        if event:
            sent["X-GitHub-Event"] = event
        return self.http.post(path, content=body, headers=sent)

    def status(self, payload: Any, header: str = "Signature"):
        body = self.raw(payload)
        return self.http.post("/update/status", content=body, headers=self.signed(body, header))

    @staticmethod
    def basic(user: str, password: str) -> dict[str, str]:
        return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


@pytest.fixture
def api(session, clients) -> Api:
    return Api()


@pytest.fixture
def run_jobs() -> Callable[[], int]:
    """Runs every due background job in the test process (what the worker processes do in production)."""
    from netdef_ci.jobs import handlers  # noqa: F401
    from netdef_ci.jobs.queue import Worker

    def run(limit: int = 50) -> int:
        worker = Worker(use_timeout=False, name="test-worker")
        done = 0
        while done < limit and worker.run_once():
            done += 1
        return done

    return run
