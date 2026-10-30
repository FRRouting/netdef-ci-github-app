#!/usr/bin/env python3
#  SPDX-License-Identifier: BSD-2-Clause
#
#  smoke_test.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
"""Starts the real processes (migrations, uvicorn with 2 workers, job worker) against a scratch PostgreSQL database and
exercises them over HTTP. Nothing external is contacted: no GitHub App, Bamboo or Slack is configured.

    SMOKE_ADMIN_URL=postgresql://postgres:postgres@localhost:55432/postgres python scripts/smoke_test.py
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
import psycopg

ROOT = Path(__file__).resolve().parents[1]
ADMIN_URL = os.environ.get("SMOKE_ADMIN_URL", "postgresql://postgres:postgres@localhost:55432/postgres")
DB_NAME = "netdef_smoke"
PORT = int(os.environ.get("SMOKE_PORT", "18000"))
SECRET = "smoke-secret"


def sign(body: bytes) -> dict[str, str]:
    return {"X-Hub-Signature-256": "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()}


def check(condition: bool, message: str) -> None:
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        raise SystemExit(1)


def main() -> int:
    with psycopg.connect(ADMIN_URL, autocommit=True) as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {DB_NAME} WITH (FORCE)")
        conn.execute(f"CREATE DATABASE {DB_NAME}")
    tmp = Path(tempfile.mkdtemp(prefix="netdef-smoke-"))
    base = ADMIN_URL.rsplit("/", 1)[0].replace("postgresql://", "postgresql+psycopg://")
    env = {
        **os.environ,
        "PYTHONPATH": str(ROOT / "src"),
        "NETDEF_ENV": "production",
        "DATABASE_URL": f"{base}/{DB_NAME}",
        "WEBHOOK_SECRET": SECRET,
        "METRICS_USERNAME": "prom",
        "METRICS_PASSWORD": "prompass",
        "PROMETHEUS_MULTIPROC_DIR": str(tmp / "prom"),
        "LOG_DIR": str(tmp / "logs"),
        "JOB_SLEEP_DELAY_SECONDS": "0.5",
        "WEB_WORKERS": "2",
    }
    py = sys.executable
    subprocess.run([py, "-m", "netdef_ci", "migrate"], env=env, check=True)
    check(True, "alembic migrations applied to an empty database")
    web = subprocess.Popen(
        [py, "-m", "uvicorn", "--factory", "netdef_ci.web.app:app_factory", "--port", str(PORT), "--workers", "2"],
        env=env,
    )
    worker = subprocess.Popen([py, "-m", "netdef_ci", "worker"], env=env)
    url = f"http://127.0.0.1:{PORT}"
    try:
        for _ in range(60):
            try:
                if httpx.get(f"{url}/readyz", timeout=2).status_code == 200:
                    break
            except httpx.HTTPError:
                time.sleep(0.5)
        else:
            check(False, "server became ready")
        check(httpx.get(f"{url}/ping").text == "Pong", "GET /ping")
        check(httpx.get(f"{url}/healthz").json()["status"] == "ok", "GET /healthz")
        check(httpx.get(f"{url}/readyz").json()["database"] == "ok", "GET /readyz (database reachable)")
        body = b"{}"
        check(
            httpx.post(url, content=body, headers={"X-GitHub-Event": "ping", **sign(body)}).text == "PONG!",
            "signed ping webhook",
        )
        check(
            httpx.post(url, content=body, headers={"X-GitHub-Event": "ping"}).status_code == 404,
            "unsigned webhook rejected (404)",
        )
        check(
            httpx.post(
                url, content=body, headers={"X-GitHub-Event": "ping", "X-Hub-Signature-256": "sha256=00"}
            ).status_code
            == 401,
            "wrong signature rejected (401)",
        )
        pr = json.dumps(
            {
                "action": "opened",
                "number": 1,
                "repository": {"full_name": "o/r"},
                "pull_request": {
                    "user": {"login": "u", "id": 1},
                    "head": {"ref": "b", "sha": "1" * 40},
                    "base": {"ref": "main", "sha": "2" * 40},
                },
            }
        ).encode()
        reply = httpx.post(url, content=pr, headers={"X-GitHub-Event": "pull_request", **sign(pr)})
        # no GitHub App is configured (the user lookup is skipped, not fatal) and no plan exists for o/r
        check(
            reply.status_code == 422 and reply.text == "No Plans associated with this Pull Request",
            "pull_request without plans is 422",
        )
        check(httpx.get(f"{url}/metrics").status_code == 401, "/metrics requires credentials")
        for _ in range(8):  # spread the requests over both uvicorn workers
            httpx.get(f"{url}/ping")
        metrics = httpx.get(f"{url}/metrics", auth=("prom", "prompass")).text
        line = next(
            x
            for x in metrics.splitlines()
            if x.startswith('http_requests_total{method="GET",path="/ping",status="200"}')
        )
        check(float(line.split()[-1]) >= 8, f"metrics aggregate the web workers ({line})")
        check("delayed_jobs_pending" in metrics, "database gauges present in /metrics")
        # /readyz only proves that one worker is up; the second one may still be starting, so wait for it (bounded).
        for _ in range(30):
            booted = next(x for x in metrics.splitlines() if x.startswith("puma_booted_workers"))
            if booted.split()[-1] == "2.0":
                break
            time.sleep(0.5)
            metrics = httpx.get(f"{url}/metrics", auth=("prom", "prompass")).text
        check(booted.split()[-1] == "2.0", f"both web workers are reported ({booted})")
    finally:
        for proc in (web, worker):
            proc.send_signal(signal.SIGTERM)
        for proc in (web, worker):
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proc.kill()
    check(worker.returncode == 0, f"worker stopped gracefully on SIGTERM (exit {worker.returncode})")
    print("smoke test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
