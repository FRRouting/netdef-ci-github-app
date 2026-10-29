#  SPDX-License-Identifier: BSD-2-Clause
#
#  logs.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Logging: stdout (journald) + optional files (main log and one per pull request), with secret redaction."""

from __future__ import annotations

import fcntl
import logging
import os
import re
import sys
from logging.handlers import WatchedFileHandler
from pathlib import Path

from netdef_ci.config import get_settings

ROOT = "netdef_ci"
_REDACTIONS = [
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._\-]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(signature_secret=)[^&\s\"']+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)((?:password|secret|token)['\"]?\s*[:=]\s*['\"]?)[^\"',\s&}]+"), r"\1[REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "[REDACTED]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[REDACTED KEY]"),
    (re.compile(r"(?i)(sha256=)[0-9a-f]{16,}"), r"\1[REDACTED]"),
]


def redact(text: str) -> str:
    for pattern, replacement in _REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


class RedactingFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact(record.getMessage())
        record.args = None
        return True


_configured = False
_file_handlers: dict[str, logging.Handler] = {}


def configure_logging(force: bool = False) -> None:
    global _configured
    if _configured and not force:
        return
    settings = get_settings()
    root = logging.getLogger(ROOT)
    root.handlers.clear()
    root.setLevel(logging.DEBUG if settings.debug else logging.INFO)
    root.propagate = False
    fmt = logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s")
    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(fmt)
    stream.addFilter(RedactingFilter())
    root.addHandler(stream)
    if settings.log_dir:
        root.addHandler(_file_handler("github_app.log", fmt))
    _configured = True


def _file_handler(filename: str, fmt: logging.Formatter | None = None) -> logging.Handler:
    settings = get_settings()
    if filename in _file_handlers:
        return _file_handlers[filename]
    directory = Path(settings.log_dir or ".")
    directory.mkdir(parents=True, exist_ok=True)
    # Several processes (web workers, job workers) append to the same files: rotation is delegated to logrotate and
    # WatchedFileHandler reopens the file when it is rotated.
    handler = WatchedFileHandler(directory / filename, encoding="utf-8")
    handler.setFormatter(fmt or logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s"))
    handler.addFilter(RedactingFilter())
    _file_handlers[filename] = handler
    return handler


class SizeRotatingFileHandler(WatchedFileHandler):
    """Rotates the file by size and keeps `files` files in total (`name`, `name.1`, ...); with `files=1` the file is
    restarted. Safe with several processes: rotation happens under an `flock` and the other processes reopen the new
    file on their next write (WatchedFileHandler), unlike `RotatingFileHandler`, whose processes rotate independently."""

    def __init__(self, filename: Path, max_bytes: int, files: int) -> None:
        super().__init__(filename, encoding="utf-8")
        self.max_bytes = max_bytes
        self.files = files

    def emit(self, record: logging.LogRecord) -> None:
        try:
            if self._too_big():
                self._rotate()
        except OSError:
            self.handleError(record)
        super().emit(record)

    def _too_big(self) -> bool:
        try:
            return os.stat(self.baseFilename).st_size >= self.max_bytes
        except FileNotFoundError:
            return False

    def _rotate(self) -> None:
        with open(f"{self.baseFilename}.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not self._too_big():  # another process rotated it while we waited for the lock
                return
            for index in range(self.files - 2, 0, -1):
                older = f"{self.baseFilename}.{index}"
                if os.path.exists(older):
                    os.replace(older, f"{self.baseFilename}.{index + 1}")
            if self.files > 1:
                os.replace(self.baseFilename, f"{self.baseFilename}.1")
            else:
                os.remove(self.baseFilename)
        self.reopenIfNeeded()


def github_http_logger() -> logging.Logger:
    """Logger for the GitHub API calls (`<METHOD> <URL> -> <status>`): `github_http.log` in LOG_DIR, else stdout."""
    configure_logging()
    logger = logging.getLogger(f"{ROOT}.github_http")
    settings = get_settings()
    if settings.log_dir and not logger.handlers:
        directory = Path(settings.log_dir)
        directory.mkdir(parents=True, exist_ok=True)
        files = settings.github_http_log_files or (5 if settings.env == "production" else 1)
        handler = SizeRotatingFileHandler(directory / "github_http.log", settings.github_http_log_max_bytes, files)
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        handler.addFilter(RedactingFilter())
        logger.addHandler(handler)
        logger.propagate = False
    return logger


class Log:
    """Component logger that also mirrors into `pr<N>.log` when a pull request id is known."""

    def __init__(self, component: str, pr_id: int | str | None = None) -> None:
        configure_logging()
        self._loggers = [logging.getLogger(f"{ROOT}.{component}")]
        if pr_id is not None:
            self._loggers.append(self._pr_logger(pr_id))

    @staticmethod
    def _pr_logger(pr_id: int | str) -> logging.Logger:
        logger = logging.getLogger(f"{ROOT}.pr.{pr_id}")
        settings = get_settings()
        if settings.log_dir and not logger.handlers:
            logger.addHandler(_file_handler(f"pr{pr_id}.log"))
            logger.propagate = False
        return logger

    def _emit(self, level: int, msg: str, *args: object) -> None:
        for logger in self._loggers:
            logger.log(level, msg, *args)

    def debug(self, msg: str, *args: object) -> None:
        self._emit(logging.DEBUG, msg, *args)

    def info(self, msg: str, *args: object) -> None:
        self._emit(logging.INFO, msg, *args)

    def warning(self, msg: str, *args: object) -> None:
        self._emit(logging.WARNING, msg, *args)

    def error(self, msg: str, *args: object) -> None:
        self._emit(logging.ERROR, msg, *args)

    def exception(self, msg: str, *args: object) -> None:
        for logger in self._loggers:
            logger.exception(msg, *args)
