#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/stage.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Stage of an execution and its GitHub check run (port of lib/models/stage.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import ForeignKey, Integer, String, exists, select
from sqlalchemy.orm import Mapped, mapped_column, relationship

from netdef_ci.enums import FAILED_STATUSES, RUNNING_STATUSES, Status
from netdef_ci.models.audit_status import AuditStatus, audit_pair
from netdef_ci.models.base import Base, BigId, Output, StatusType, _session, _ts, _ts_updated
from netdef_ci.models.ci_job import CiJob

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.clients.github import GithubCheck
    from netdef_ci.models.check_suite import CheckSuite
    from netdef_ci.models.stage_configuration import StageConfiguration


class Stage(Base):
    __tablename__ = "stages"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    check_ref: Mapped[str | None] = mapped_column(String, index=True)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated(index=True)
    check_suite_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("check_suites.id"), index=True)
    stage_configuration_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("stage_configurations.id"), index=True)
    execution_time: Mapped[int | None] = mapped_column(Integer)

    check_suite: Mapped[CheckSuite | None] = relationship(back_populates="stages", foreign_keys=[check_suite_id])
    configuration: Mapped[StageConfiguration | None] = relationship(foreign_keys=[stage_configuration_id])
    jobs: Mapped[list[CiJob]] = relationship(back_populates="stage", order_by="CiJob.id", foreign_keys="CiJob.stage_id")

    # --- state helpers ----------------------------------------------------------------------
    @property
    def state(self) -> Status:
        return Status(self.status)

    def jobs_with(self, *statuses: Status) -> list[CiJob]:
        return list(
            _session(self).scalars(
                select(CiJob).where(CiJob.stage_id == self.id, CiJob.status.in_(list(statuses))).order_by(CiJob.id)
            )
        )

    def jobs_without(self, *statuses: Status) -> list[CiJob]:
        return list(
            _session(self).scalars(
                select(CiJob).where(CiJob.stage_id == self.id, CiJob.status.not_in(list(statuses))).order_by(CiJob.id)
            )
        )

    def all_jobs(self) -> list[CiJob]:
        return list(_session(self).scalars(select(CiJob).where(CiJob.stage_id == self.id).order_by(CiJob.id)))

    def failed_jobs(self) -> list[CiJob]:
        return self.jobs_with(*FAILED_STATUSES)

    def is_running(self) -> bool:
        return bool(
            _session(self).scalar(
                select(exists().where(CiJob.stage_id == self.id, CiJob.status.in_(list(RUNNING_STATUSES))))
            )
        )

    def is_finished(self) -> bool:
        return not self.is_running()

    def suffix(self) -> str:
        return self.name.split(" - ")[-1]

    def full_name(self) -> str:
        return f"[CI] {self.name}"

    def update_execution_time(self) -> None:
        started, finished = audit_pair(self, "Stage")
        if started is None or finished is None:
            return
        self.execution_time = int((finished.created_at - started.created_at).total_seconds())
        _session(self).commit()

    # --- transitions (port of lib/models/stage.rb) ---------------------------------------------
    def enqueue(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        # A new check run is already queued: sending the output with it saves a PATCH that GitHub often answered 404
        # (read-after-write lag), plus the GET and back-off of its verification, while the PR lock is held.
        check_run = github.create(self.full_name(), output=output)
        self._record(Status.QUEUED, agent, check_ref=str(check_run["id"]))

    def in_progress(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        if self.state == Status.IN_PROGRESS:
            return
        if output is None:
            output = self.output_in_progress()
        self._create_github_check(github)
        assert self.check_ref is not None
        github.in_progress(self.check_ref, output)
        self._record(Status.IN_PROGRESS, agent)
        from netdef_ci import container

        container.slack().stage_in_progress_notification(self)

    def update_output(self, github: GithubCheck, output: Output | None = None) -> None:
        assert self.check_ref is not None
        github.in_progress(self.check_ref, self.output_in_progress() if output is None else output)

    def cancelled(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._finish(github, Status.CANCELLED, github.cancelled, output, agent)

    def failure(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._finish(github, Status.FAILURE, github.failure, output, agent)

    def success(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._finish(github, Status.SUCCESS, github.success, output, agent)

    def _finish(self, github: GithubCheck, status: Status, call: Any, output: Output | None, agent: str) -> None:
        # An open stage concludes the check run the pull request is waiting on; a fresh one would leave it queued or
        # in progress forever. Only a stage without a check run, or one already concluded (re-conclusion), gets a
        # new check run, so the previous result stays in GitHub's history.
        if self.check_ref is None or self.state not in RUNNING_STATUSES:
            check_ref = str(github.create(self.full_name())["id"])
        else:
            check_ref = self.check_ref
        call(check_ref, output or {})
        self._record(status, agent, check_ref=check_ref)
        from netdef_ci import container

        container.slack().stage_finished_notification(self)

    def _create_github_check(self, github: GithubCheck) -> None:
        if self.check_ref is not None:
            return
        check_run = github.create(self.full_name())
        self.check_ref = str(check_run["id"])
        _session(self).commit()

    def _record(self, status: Status, agent: str, check_ref: str | None = None) -> None:
        session = _session(self)
        session.add(AuditStatus(auditable_type="Stage", auditable_id=self.id, status=status, agent=agent))
        self.status = status
        if check_ref is not None:
            self.check_ref = check_ref
        session.commit()

    def output_in_progress(self) -> Output:
        from netdef_ci.helpers.config import get_settings

        settings = get_settings()
        in_progress = self.jobs_with(Status.IN_PROGRESS)
        total = len(self.all_jobs())
        header = f":arrow_right: Jobs in progress: {len(in_progress)}/{total}\n\n"
        lines = "\n".join(f"- **{job.name}** -> {settings.browse_url(job.job_ref)}\n" for job in in_progress)
        suite = self.check_suite
        url = settings.browse_url(suite.bamboo_ci_ref if suite else None)
        return {"title": f"{self.name} summary", "summary": f"{header}{lines}\nDetails at [{url}]({url})"}
