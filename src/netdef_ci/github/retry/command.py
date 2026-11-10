#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/retry/command.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""check_run `rerequested`, the Re-run button of a single check run (port of Github::Retry::Command)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.github.retry.base import RetryBase
from netdef_ci.helpers.payload import dig
from netdef_ci.models import Stage


class RetryCommand(RetryBase):
    """check_run `rerequested` (Re-run button of a single check run)."""

    KIND = "command"

    def __init__(self, session: Session, payload: dict[str, Any]) -> None:
        super().__init__(session, payload)
        check_ref = dig(payload, "check_run", "id")
        if check_ref is not None:
            self.stage = session.scalars(
                select(Stage).where(Stage.check_ref == str(check_ref)).order_by(Stage.id.desc()).limit(1)
            ).first()
