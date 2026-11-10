#  SPDX-License-Identifier: BSD-2-Clause
#
#  github/build/retry.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Re-queues the stages and jobs of a check suite that did not pass (port of Github::Build::Retry)."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from netdef_ci.enums import Status
from netdef_ci.helpers.config import get_settings
from netdef_ci.helpers.logs import Log
from netdef_ci.models import AuditRetry, CheckSuite, Stage, StageConfiguration


class BuildRetry:
    """Re-queues the stages/jobs that did not pass (Github::Build::Retry)."""

    def __init__(self, session: Session, check_suite: CheckSuite, github: Any, audit_retry: AuditRetry) -> None:
        self.session = session
        self.check_suite = check_suite
        self.github = github
        self.audit_retry = audit_retry
        assert check_suite.pull_request is not None
        self.log = Log("github_build_retry", check_suite.pull_request.github_pr_id)
        self.log.warning(">>>> Retrying check_suite: %s", check_suite.id)

    def enqueued_stages(self) -> None:
        settings = get_settings()
        for config in self.session.scalars(select(StageConfiguration).order_by(StageConfiguration.id)):
            if not config.can_retry:
                continue
            stage = self.session.scalars(
                select(Stage)
                .where(Stage.check_suite_id == self.check_suite.id, Stage.name == config.github_check_run_name)
                .order_by(Stage.id)
                .limit(1)
            ).first()
            if stage is None or stage.state == Status.SUCCESS:
                continue
            url = settings.browse_url(self.check_suite.bamboo_ci_ref)
            stage.enqueue(
                self.github,
                output={"title": f"{stage.name} summary", "summary": f"Uninitialized stage\nDetails at [{url}]({url})"},
            )

    def enqueued_failure_tests(self) -> None:
        for ci_job in [j for j in self.check_suite.ci_jobs if j.state != Status.SUCCESS]:
            if ci_job.stage is None or ci_job.stage.configuration is None or not ci_job.stage.configuration.can_retry:
                continue
            self.log.warning("Enqueue CiJob: %s", ci_job.id)
            ci_job.enqueue(self.github, commit=False)
            ci_job.retry = (ci_job.retry or 0) + 1
            self.audit_retry.ci_jobs.append(ci_job)
        self.session.commit()
