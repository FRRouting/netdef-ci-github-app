#  SPDX-License-Identifier: BSD-2-Clause
#
#  services/message_formatter.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Markdown summary of a stage for the GitHub check run (port of Build::Summary::MessageFormatter)."""

from __future__ import annotations

import re
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import object_session, selectinload

from netdef_ci import container
from netdef_ci.config import get_settings
from netdef_ci.enums import Status
from netdef_ci.models import CiJob, Stage

MAX_SUMMARY = 65_536  # GitHub limit for the summary text


class MessageFormatter:
    def __init__(self) -> None:
        self.settings = get_settings()

    def _link(self, job: CiJob) -> str:
        return f"- **{job.name}** -> {self.settings.browse_url(job.job_ref)}\n"

    def summary_basic_output(self, stage: Stage) -> str:
        session = object_session(stage)
        assert session is not None
        # The failure section reads each failed job's topotest failures: load them in one query, not one per job.
        jobs = list(
            session.scalars(
                select(CiJob)
                .where(CiJob.stage_id == stage.id)
                .order_by(CiJob.id)
                .options(selectinload(CiJob.topotest_failures))
            )
        )
        total = len(jobs)
        queued = [j for j in jobs if j.state == Status.QUEUED]
        in_progress = [j for j in jobs if j.state == Status.IN_PROGRESS]
        header = f":arrow_right: Jobs queued: {len(queued)}/{total}\n\n" + "\n".join(self._link(j) for j in queued)
        header += f"\n\n:arrow_right: Jobs in progress: {len(in_progress)}/{total}\n\n" + "\n".join(
            self._link(j) for j in in_progress
        )
        header += self._success_failure(stage.name, jobs)
        return header[:MAX_SUMMARY]

    def summary_with_footer(self, stage: Stage, url: str) -> str:
        stamp = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
        return f"{self.summary_basic_output(stage)}\nDetails at [{url}]({url}).\n\nLast updated: {stamp}"

    def generate_message(self, name: str, job: CiJob) -> str:
        if re.search("source", name, re.I):
            failures = self._checkout_message(job)
        elif re.search("build", name, re.I):
            failures = self._build_message(job)
        else:
            failures = self._tests_message(job)
        return f"- {job.name} -> {self.settings.browse_url(job.job_ref)}\n{failures}"

    # ------------------------------------------------------------------
    def _success_failure(self, name: str, jobs: list[CiJob]) -> str:
        total = len(jobs)
        others = [j for j in jobs if j.state not in (Status.IN_PROGRESS, Status.QUEUED, Status.SUCCESS)]
        success = [j for j in jobs if j.state == Status.SUCCESS]
        sections = (
            (
                ":heavy_multiplication_x: Jobs Failure",
                "\n".join(self.generate_message(name, j) for j in others),
                len(others),
            ),
            (":heavy_check_mark: Jobs Success", "\n".join(self._link(j) for j in success), len(success)),
        )
        header = ""
        for title, queue, size in sections:
            if queue:
                header += f"\n{title}: {size}/{total}\n\n{queue}"
        return header

    @staticmethod
    def _tests_message(job: CiJob) -> str:
        failures = job.topotest_failures
        if not failures:
            return ""
        failure = failures[0]
        return f"\t :no_entry_sign: {failure.test_suite} {failure.test_case}\n ```\n{failure.message}\n```\n"

    @staticmethod
    def _checkout_message(job: CiJob) -> str:
        if job.summary is None:
            return ""
        return f"```\n{job.summary.replace('<br>', chr(10))}\n```\n"

    @staticmethod
    def _build_message(job: CiJob) -> str:
        # The summary is rebuilt many times while the execution runs; the log of a finished job does not change, so
        # it is downloaded once (`build_log` is cleared when the job runs again).
        if job.build_log:
            return f"```\n{job.build_log}\n```\n"
        bamboo = container.bamboo()
        output = bamboo.result(job.job_ref or "", expand="testResults.failedTests.testResult.errors,artifacts") or {}
        artifacts = (output.get("artifacts") or {}).get("artifact") or []
        entry = next((a for a in artifacts if a.get("name") == "ErrorLog"), None)
        if not entry:
            return ""
        body = bamboo.build_log(((entry.get("link") or {}).get("href")) or "")
        session = object_session(job)
        if body and session is not None:
            job.build_log = body
            session.commit()
        return f"```\n{body}\n```\n"
