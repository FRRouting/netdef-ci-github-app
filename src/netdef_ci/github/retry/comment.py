#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/retry/comment.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""`ci:retry` comment (port of Github::Retry::Comment)."""

from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from netdef_ci.github.retry.base import REFUSED, RetryBase
from netdef_ci.helpers.payload import dig
from netdef_ci.models import find_pull_request

Response = tuple[int, str]


class RetryComment(RetryBase):
    """`ci:retry` comment."""

    KIND = "comment"

    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        super().__init__(session, payload)
        pull_request = find_pull_request(
            session, dig(payload, "issue", "number"), dig(payload, "repository", "full_name")
        )
        if pull_request is not None:
            self.check_suite = pull_request.last_check_suite()
            if self.check_suite is not None:
                failing = self.check_suite.stages_failure()
                self.stage = min(failing, key=lambda s: s.id) if failing else None
        self.comment_id = dig(payload, "comment", "id")

    def start(self) -> Response:
        output = super().start()
        self.log.info("Github::Retry::Comment - response %s", output)
        self._reaction(self.comment_id, up=output[0] not in REFUSED)
        return output

    def schedule(self) -> Response:
        output = super().schedule()
        if output[0] in REFUSED:  # refused now; the job reacts to the outcome of a scheduled retry
            self._reaction(self.comment_id, up=False)
        return output
