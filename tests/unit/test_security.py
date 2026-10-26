#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_security.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import base64

from netdef_ci.config import Credentials
from netdef_ci.security import check_basic, compute_signature, parse_basic, verify_hmac

SECRET = "s3cret"
BODY = b'{"a": 1}'


def test_valid_signature_over_raw_body() -> None:
    assert verify_hmac(SECRET, BODY, compute_signature(SECRET, BODY)).ok


def test_signature_is_computed_over_the_exact_bytes_not_a_reserialization() -> None:
    reformatted = b'{"a":1}'
    assert not verify_hmac(SECRET, reformatted, compute_signature(SECRET, BODY)).ok


def test_missing_signature_is_404() -> None:
    result = verify_hmac(SECRET, BODY, None)
    assert (result.ok, result.status, result.message) == (False, 404, "Signature not found")


def test_mismatching_signature_is_401() -> None:
    result = verify_hmac(SECRET, BODY, "sha256=" + "0" * 64)
    assert (result.ok, result.status, result.message) == (False, 401, "Signatures didn't match!")


def test_wrong_secret_and_unprefixed_signature_are_rejected() -> None:
    assert not verify_hmac("other", BODY, compute_signature(SECRET, BODY)).ok
    assert not verify_hmac(SECRET, BODY, compute_signature(SECRET, BODY).removeprefix("sha256=")).ok


def test_empty_body_is_401_without_message() -> None:
    result = verify_hmac(SECRET, b"", compute_signature(SECRET, b""))
    assert (result.ok, result.status, result.message) == (False, 401, "")


def test_empty_secret_rejects_everything() -> None:
    assert not verify_hmac("", BODY, compute_signature("", BODY)).ok


def test_non_ascii_header_does_not_raise() -> None:
    assert not verify_hmac(SECRET, BODY, "sha256=çãõ").ok


def test_basic_auth_helpers() -> None:
    header = "Basic " + base64.b64encode(b"user:pa:ss").decode()
    assert parse_basic(header) == ("user", "pa:ss")
    assert check_basic(header, Credentials("user", "pa:ss"))
    assert not check_basic(header, Credentials("user", "x"))
    assert not check_basic(header, None)
    assert not check_basic("Bearer abc", Credentials("user", "pa:ss"))
    assert not check_basic("Basic !!!", Credentials("user", "pa:ss"))
    assert not check_basic(None, Credentials("user", "pa:ss"))
