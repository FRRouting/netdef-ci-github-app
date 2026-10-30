#  SPDX-License-Identifier: BSD-2-Clause
#
#  clients/http.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Small helpers shared by the HTTP clients: bounded retries only for idempotent calls."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable

import httpx

IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "PUT", "PATCH", "DELETE"})
RETRY_STATUS = frozenset({502, 503, 504})
RETRY_ERRORS = (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout, httpx.RemoteProtocolError)
MAX_RETRY_AFTER_SECONDS = 60.0

Sleeper = Callable[[float], None]


def retry_after_seconds(response: httpx.Response) -> float | None:
    """Seconds to wait when GitHub (or a proxy) signals a rate limit; None when it is not a rate limit."""
    header = response.headers.get("retry-after")
    if header and header.isdigit():
        return min(float(header), MAX_RETRY_AFTER_SECONDS)
    if response.status_code in (403, 429):
        remaining = response.headers.get("x-ratelimit-remaining")
        reset = response.headers.get("x-ratelimit-reset")
        if remaining == "0" and reset and reset.isdigit():
            return max(0.0, min(float(int(reset) - time.time()), MAX_RETRY_AFTER_SECONDS))
        if response.status_code == 429:
            return 5.0
        if "secondary rate limit" in response.text.lower():
            return 10.0
    return None


def request_with_retries(
    client: httpx.Client,
    method: str,
    url: str,
    *,
    max_retries: int,
    sleep: Sleeper = time.sleep,
    logger: logging.Logger | logging.LoggerAdapter[logging.Logger] | None = None,
    **kwargs: object,
) -> httpx.Response:
    """Send a request retrying (at most `max_retries` times) on transport errors / 5xx for idempotent methods and on
    rate-limit responses for every method (the server rejected the request, so repeating it is safe).

    With `logger`, every attempt is logged as `<METHOD> <URL> -> <HTTP status>` (or the transport error)."""
    attempt = 0
    while True:
        try:
            response = client.request(method, url, **kwargs)  # type: ignore[arg-type]
        except httpx.HTTPError as error:
            if logger is not None:
                logger.warning("%s %s -> %s: %s", method.upper(), url, type(error).__name__, error)
            if (
                not isinstance(error, RETRY_ERRORS)
                or method.upper() not in IDEMPOTENT_METHODS
                or attempt >= max_retries
            ):
                raise
            attempt += 1
            sleep(min(2.0**attempt, 10.0))
            continue
        if logger is not None:
            level = logging.WARNING if response.status_code >= 400 else logging.INFO
            logger.log(level, "%s %s -> %s", method.upper(), response.request.url, response.status_code)
        wait = retry_after_seconds(response)
        retryable = wait is not None or (method.upper() in IDEMPOTENT_METHODS and response.status_code in RETRY_STATUS)
        if retryable and attempt < max_retries:
            attempt += 1
            sleep(wait if wait is not None else min(2.0**attempt, 10.0))
            continue
        return response
