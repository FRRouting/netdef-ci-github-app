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
from collections import OrderedDict
from collections.abc import MutableMapping
from logging.handlers import WatchedFileHandler
from pathlib import Path
from typing import Any, TextIO

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
        # The same record reaches several handlers (stdout, main file, pull request file): redact it only once.
        if getattr(record, "_netdef_redacted", False):
            return True
        record.msg = redact(record.getMessage())
        record.args = None
        record._netdef_redacted = True
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


class PullRequestFilesHandler(logging.Handler):
    """Writes each record to the `pr<N>.log` of its pull request (`record.pr_id`). One handler per process keeps at
    most `max_open` files open (the least recently used is closed and reopened on its next line) and, like
    WatchedFileHandler, reopens a file that logrotate moved away. No logger or handler object per pull request."""

    def __init__(self, directory: Path, max_open: int) -> None:
        super().__init__()
        self.directory = directory
        self.max_open = max_open
        self._streams: OrderedDict[str, tuple[TextIO, int, int]] = OrderedDict()

    def emit(self, record: logging.LogRecord) -> None:  # called under self.lock (Handler.handle)
        try:
            stream = self._stream(str(getattr(record, "pr_id", "-")))
            stream.write(self.format(record) + "\n")
            stream.flush()
        except Exception:
            self.handleError(record)

    def _stream(self, pr_id: str) -> TextIO:
        path = self.directory / f"pr{pr_id}.log"
        entry = self._streams.get(pr_id)
        if entry is not None:
            stream, dev, ino = entry
            try:
                current = os.stat(path)
                rotated = (current.st_dev, current.st_ino) != (dev, ino)
            except FileNotFoundError:
                rotated = True
            if not rotated:
                self._streams.move_to_end(pr_id)
                return stream
            del self._streams[pr_id]
            stream.close()
        stream = open(path, "a", encoding="utf-8")  # noqa: SIM115 - kept open across records
        opened = os.fstat(stream.fileno())
        self._streams[pr_id] = (stream, opened.st_dev, opened.st_ino)
        while len(self._streams) > self.max_open:
            _oldest, (old, _dev, _ino) = self._streams.popitem(last=False)
            old.close()
        return stream

    @property
    def open_files(self) -> int:
        return len(self._streams)

    def close(self) -> None:
        self.acquire()
        try:
            for stream, _dev, _ino in self._streams.values():
                stream.close()
            self._streams.clear()
        finally:
            self.release()
        super().close()


class SizeRotatingFileHandler(WatchedFileHandler):
    """Rotates the file by size and keeps `files` files in total (`name`, `name.1`, ...); with `files=1` the file is
    restarted. Safe with several processes: rotation happens under an `flock` and the other processes reopen the new
    file on their next write (WatchedFileHandler), unlike `RotatingFileHandler`, whose processes rotate independently."""

    def __init__(self, filename: Path, max_bytes: int, files: int) -> None:
        super().__init__(filename, encoding="utf-8")
        self.max_bytes = max_bytes
        self.files = files
        # The size is checked (one stat) after this process wrote ~1/1000 of the limit (at most 1 MiB), not on every
        # line: the file may grow past the limit by that much per process before it rotates.
        self._check_every = max(1, min(max_bytes // 1000, 1024**2))
        self._unchecked = self._check_every  # check on the first record

    def emit(self, record: logging.LogRecord) -> None:
        try:
            if self._unchecked >= self._check_every:
                self._unchecked = 0
                if self._too_big():
                    self._rotate()
        except OSError:
            self.handleError(record)
        super().emit(record)
        self._unchecked += len(record.getMessage()) + 64  # message plus timestamp/level prefix, approximately

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


class PullRequestAdapter(logging.LoggerAdapter[logging.Logger]):
    """Prefixes each message with the pull request that caused it (`[PR 123]`, or `[PR -]` when unknown)."""

    def __init__(self, logger: logging.Logger, pr_id: int | str | None) -> None:
        super().__init__(logger)
        self.pr_id = pr_id

    def process(self, msg: Any, kwargs: MutableMapping[str, Any]) -> tuple[Any, MutableMapping[str, Any]]:
        return f"[PR {self.pr_id if self.pr_id is not None else '-'}] {msg}", kwargs


def github_http_logger(pr_id: int | str | None = None) -> PullRequestAdapter:
    """Logger for the GitHub API calls (`[PR <N>] <METHOD> <URL> -> <status>`): `github_http.log` in LOG_DIR, else
    stdout."""
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
    return PullRequestAdapter(logger, pr_id)


def _pr_logger() -> logging.Logger | None:
    """The one logger behind every `pr<N>.log` (None without LOG_DIR: the component logger already reaches stdout,
    and a per-PR copy would print every line twice)."""
    settings = get_settings()
    if not settings.log_dir:
        return None
    logger = logging.getLogger(f"{ROOT}.pull_requests")
    if not any(isinstance(handler, PullRequestFilesHandler) for handler in logger.handlers):
        directory = Path(settings.log_dir)
        directory.mkdir(parents=True, exist_ok=True)
        handler = PullRequestFilesHandler(directory, settings.pr_log_open_files)
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s [%(component)s] %(message)s"))
        handler.addFilter(RedactingFilter())
        logger.addHandler(handler)
        logger.propagate = False
    return logger


class Log:
    """Component logger that also mirrors into `pr<N>.log` when a pull request id is known and LOG_DIR is set."""

    def __init__(self, component: str, pr_id: int | str | None = None) -> None:
        configure_logging()
        self._logger = logging.getLogger(f"{ROOT}.{component}")
        self._pr_id = pr_id
        self._pr = _pr_logger() if pr_id is not None else None

    def _emit(self, level: int, msg: str, *args: object, exc_info: bool = False) -> None:
        self._logger.log(level, msg, *args, exc_info=exc_info)
        if self._pr is not None:
            extra = {"pr_id": self._pr_id, "component": self._logger.name}
            self._pr.log(level, msg, *args, exc_info=exc_info, extra=extra)

    def debug(self, msg: str, *args: object) -> None:
        self._emit(logging.DEBUG, msg, *args)

    def info(self, msg: str, *args: object) -> None:
        self._emit(logging.INFO, msg, *args)

    def warning(self, msg: str, *args: object) -> None:
        self._emit(logging.WARNING, msg, *args)

    def error(self, msg: str, *args: object) -> None:
        self._emit(logging.ERROR, msg, *args)

    def exception(self, msg: str, *args: object) -> None:
        self._emit(logging.ERROR, msg, *args, exc_info=True)
