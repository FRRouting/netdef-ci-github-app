#  SPDX-License-Identifier: BSD-2-Clause
#
#  ../payloads.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Sanitized, synthetic webhook payloads."""

from __future__ import annotations

from typing import Any

SHA = "1" * 40
BASE_SHA = "2" * 40


def pull_request(
    number: int = 7,
    action: str = "opened",
    repo: str = "org/repo",
    sha: str = SHA,
    author: str = "alice",
    user_id: int = 4242,
) -> dict[str, Any]:
    return {
        "action": action,
        "number": number,
        "repository": {"full_name": repo},
        "pull_request": {
            "user": {"login": author, "id": user_id},
            "head": {"ref": "feature", "sha": sha},
            "base": {"ref": "main", "sha": BASE_SHA},
        },
        "sender": {"login": author, "id": user_id, "type": "User"},
    }


def issue_comment(
    body: str,
    number: int = 7,
    repo: str = "org/repo",
    comment_id: int = 99,
    action: str = "created",
    sender: str = "bob",
) -> dict[str, Any]:
    return {
        "action": action,
        "issue": {"number": number},
        "comment": {"id": comment_id, "body": body, "user": {"login": sender}},
        "repository": {"full_name": repo},
        "sender": {"login": sender, "id": 777, "type": "User"},
    }


def check_run(check_id: int | None, action: str = "rerequested") -> dict[str, Any]:
    return {"action": action, "check_run": {"id": check_id}, "sender": {"login": "bob", "id": 777, "type": "User"}}


def check_suite(sha: str, number: int = 7, repo: str = "org/repo", action: str = "rerequested") -> dict[str, Any]:
    return {
        "action": action,
        "check_suite": {"head_sha": sha, "pull_requests": [{"number": number}]},
        "repository": {"full_name": repo},
        "sender": {"login": "bob", "id": 777, "type": "User"},
    }
