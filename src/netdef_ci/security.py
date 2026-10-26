#  SPDX-License-Identifier: BSD-2-Clause
#
#  security.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Request authentication: HMAC-SHA256 over the raw body (GitHub webhooks and Bamboo callbacks) and Basic auth."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
from dataclasses import dataclass

from netdef_ci.config import Credentials


@dataclass(frozen=True)
class AuthResult:
    ok: bool
    status: int = 200
    message: str = ""


def compute_signature(secret: str, body: bytes) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def verify_hmac(secret: str, body: bytes, signature_header: str | None) -> AuthResult:
    """Decision order: empty body 401, missing signature 404, mismatch 401."""
    if not body:
        return AuthResult(False, 401, "")
    if not secret:
        return AuthResult(False, 401, "Signatures didn't match!")
    if not signature_header:
        return AuthResult(False, 404, "Signature not found")
    expected = compute_signature(secret, body)
    if not hmac.compare_digest(expected.encode(), signature_header.encode()):
        return AuthResult(False, 401, "Signatures didn't match!")
    return AuthResult(True)


def parse_basic(header: str | None) -> tuple[str, str] | None:
    if not header or not header.startswith("Basic "):
        return None
    try:
        decoded = base64.b64decode(header[6:], validate=False).decode("utf-8")
    except binascii.Error, UnicodeDecodeError:
        return None
    user, sep, password = decoded.partition(":")
    return (user, password) if sep else None


def _same(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())


def check_basic(header: str | None, expected: Credentials | None) -> bool:
    if expected is None:
        return False
    parsed = parse_basic(header)
    if parsed is None:
        return False
    user_ok = _same(expected.username, parsed[0])
    pass_ok = _same(expected.password, parsed[1])
    return user_ok and pass_ok
