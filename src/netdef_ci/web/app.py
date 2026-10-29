#  SPDX-License-Identifier: BSD-2-Clause
#
#  web/app.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""FastAPI application: routes, authentication and responses of the service."""

from __future__ import annotations

import json
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, Response
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import text

from netdef_ci import __version__, metrics
from netdef_ci.config import get_settings
from netdef_ci.db import get_engine, init_engine, session_factory, session_scope
from netdef_ci.jobs import handlers as _handlers  # noqa: F401  (registers job handlers)
from netdef_ci.logs import Log, configure_logging
from netdef_ci.security import check_basic, verify_hmac
from netdef_ci.services import slack_commands
from netdef_ci.services.finished import schedule_finished
from netdef_ci.services.update_status import UpdateStatus
from netdef_ci.web import webhooks

log = Log("github_app")
STARTED = time.time()


def _text(status: int, body: str, media_type: str = "text/plain") -> Response:
    if status in (204, 304):  # Rack drops the body of these statuses
        return Response(status_code=status)
    return Response(
        content=body,
        status_code=status,
        media_type=media_type,
        headers={"content-type": f"{media_type}; charset=utf-8"},
    )


def _json_error() -> Response:
    return Response(
        content=json.dumps({"error": "Internal Server Error"}), status_code=500, media_type="application/json"
    )


class CollapseLeadingSlashes:
    """ASGI middleware: `//ping` (what `proxy_pass http://host/;` produces behind a prefix location) -> `/ping`."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] in ("http", "websocket") and scope.get("path", "").startswith("//"):
            path = "/" + scope["path"].lstrip("/")
            scope = {**scope, "path": path, "raw_path": path.encode()}
        await self.app(scope, receive, send)


def create_app(*, init_database: bool = True) -> FastAPI:
    configure_logging()
    settings = get_settings()

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        if settings.env == "production" and not settings.webhook_secret.get_secret_value():
            raise RuntimeError("WEBHOOK_SECRET must be set in production")
        if init_database:
            init_engine()
        metrics.cleanup_stale_metric_files()
        from anyio.to_thread import current_default_thread_limiter

        metrics.web_worker_started(int(current_default_thread_limiter().total_tokens))
        yield

    app = FastAPI(
        title="NetDEF CI GitHub App",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )

    app.add_middleware(CollapseLeadingSlashes)

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Any]) -> Response:
        start = time.monotonic()
        event = request.headers.get("x-github-event")
        metrics.web_request_in_flight(1)
        try:
            response: Response = await call_next(request)
        except Exception as error:
            metrics.HTTP_SERVER_EXCEPTIONS.labels(exception=type(error).__name__).inc()
            raise
        finally:
            metrics.web_request_in_flight(-1)
        route = request.scope.get("route")
        path = "/*" if getattr(route, "path", "") == "/{full_path:path}" else getattr(route, "path", "unmatched")
        metrics.HTTP_REQUESTS.labels(method=request.method, path=path, status=str(response.status_code)).inc()
        metrics.HTTP_REQUEST_DURATION.labels(path=path).observe(time.monotonic() - start)
        metrics.HTTP_SERVER_REQUESTS.labels(code=str(response.status_code), method=request.method, path=path).inc()
        metrics.HTTP_SERVER_DURATION.labels(method=request.method, path=path).observe(time.monotonic() - start)
        if event:
            result = "processed" if response.status_code < 400 else "error"
            metrics.GITHUB_WEBHOOK_EVENTS.labels(event=event, result=result).inc()
        return response

    def guarded(handler: Callable[[Request], Any]) -> Callable[[Request], Any]:
        """Count the exception and answer a generic 500."""

        async def wrapper(request: Request) -> Response:
            try:
                return await handler(request)  # type: ignore[no-any-return]
            except Exception as error:
                first = [p for p in request.url.path.split("/") if p]
                metrics.HTTP_SERVER_EXCEPTIONS.labels(exception=type(error).__name__).inc()
                metrics.APP_EXCEPTIONS.labels(
                    **{"class": type(error).__name__, "handler": first[0] if first else "root"}
                ).inc()
                log.error("Unhandled %s on %s: %s", type(error).__name__, request.url.path, error)
                return _json_error()

        wrapper.__name__ = handler.__name__
        return wrapper

    # ------------------------------------------------------------------ operational endpoints
    @app.get("/ping")
    async def ping() -> Response:
        return _text(200, "Pong")

    @app.get("/healthz")
    async def healthz() -> Response:
        return _text(200, json.dumps({"status": "ok", "version": __version__}), "application/json")

    @app.get("/readyz")
    @guarded
    async def readyz(request: Request) -> Response:
        def check() -> dict[str, str]:
            with session_scope() as session:
                session.execute(text("SELECT 1"))
            return {"database": "ok"}

        try:
            checks = await run_in_threadpool(check)
        except Exception as error:
            return _text(
                503, json.dumps({"status": "unavailable", "database": type(error).__name__}), "application/json"
            )
        return _text(200, json.dumps({"status": "ready", **checks}), "application/json")

    @app.get("/telemetry")
    async def telemetry() -> Response:
        engine = get_engine()
        pool = getattr(engine.pool, "status", lambda: "")()
        body = {"version": __version__, "uptime_seconds": int(time.time() - STARTED), "db_pool": pool}
        return _text(200, json.dumps(body), "application/json")

    @app.get("/metrics")
    @guarded
    async def metrics_endpoint(request: Request) -> Response:
        user, password = settings.metrics_username, settings.metrics_password
        expected = None
        if user and password is not None:
            from netdef_ci.config import Credentials

            expected = Credentials(user, password.get_secret_value())
        if not check_basic(request.headers.get("authorization"), expected):
            return _text(401, "Unauthorized")
        engine = get_engine()
        body = await run_in_threadpool(metrics.render, session_factory(), engine)
        return Response(content=body, media_type="text/plain; version=0.0.4; charset=utf-8")

    # ------------------------------------------------------------------ Bamboo callback
    @app.post("/update/status")
    @guarded
    async def update_status(request: Request) -> Response:
        raw = await request.body()
        auth = verify_hmac(
            settings.webhook_secret.get_secret_value(),
            raw,
            request.headers.get("signature") or request.headers.get("x-hub-signature-256"),
        )
        if not auth.ok:
            return _text(auth.status, auth.message, "application/json")
        payload = _parse_object(raw)
        if payload is None:
            return _text(400, "Invalid JSON payload", "application/json")
        log.info("Received event UpdateStatus: status=%s ref=%s", payload.get("status"), payload.get("bamboo_ref"))

        def work() -> tuple[int, str]:
            with session_scope() as session:
                if payload.get("status") == "finished":
                    return schedule_finished(session, payload)
                return UpdateStatus(session, payload).update()

        status, body = await run_in_threadpool(work)
        return _text(status, body, "application/json")

    # ------------------------------------------------------------------ Slack
    def slack_authorized(request: Request) -> bool:
        return check_basic(request.headers.get("authorization"), settings.slack_credentials())

    @app.post("/slack")
    @guarded
    async def slack(request: Request) -> Response:
        if not slack_authorized(request):
            return _text(401, "")
        payload = _parse_object(await request.body())
        if payload is None:
            return _text(400, "Invalid JSON payload")

        def work() -> str:
            with session_scope() as session:
                if "event" in payload:
                    return slack_commands.running(session, payload)
                return slack_commands.subscribe(session, payload)

        return _text(200, await run_in_threadpool(work), "text/html")

    @app.post("/slack/settings")
    @guarded
    async def slack_settings(request: Request) -> Response:
        if not slack_authorized(request):
            return _text(401, "")
        payload = _parse_object(await request.body())
        if payload is None:
            return _text(400, "Invalid JSON payload")

        def work() -> str:
            with session_scope() as session:
                return slack_commands.settings(session, payload)

        return _text(200, await run_in_threadpool(work), "text/html")

    # ------------------------------------------------------------------ GitHub webhooks (catch-all)
    @app.post("/{full_path:path}")
    @guarded
    async def github_webhook(request: Request) -> Response:
        raw = await request.body()
        auth = verify_hmac(
            settings.webhook_secret.get_secret_value(),
            raw,
            request.headers.get("signature") or request.headers.get("x-hub-signature-256"),
        )
        if not auth.ok:
            return _text(auth.status, auth.message)
        payload = _parse_object(raw)
        if payload is None:
            return _text(400, "Invalid JSON payload")
        event = request.headers.get("x-github-event")
        delivery = request.headers.get("x-github-delivery")
        log.info("Webhook event=%s delivery=%s", event, delivery)

        def work() -> tuple[int, str]:
            with session_scope() as session:
                if not webhooks.register_delivery(session, delivery, event):
                    log.warning("Duplicate delivery %s ignored", delivery)
                    return 200, "Duplicate delivery ignored"
                return webhooks.dispatch(session, event, payload)

        status, body = await run_in_threadpool(work)
        return _text(status, body)

    return app


def _parse_object(raw: bytes) -> dict[str, Any] | None:
    try:
        data = json.loads(raw)
    except ValueError, UnicodeDecodeError:
        return None
    return data if isinstance(data, dict) else None


def app_factory() -> FastAPI:
    """Entry point for `uvicorn --factory netdef_ci.web.app:app_factory`."""
    return create_app()
