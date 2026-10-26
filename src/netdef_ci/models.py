#  SPDX-License-Identifier: BSD-2-Clause
#
#  models.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""SQLAlchemy models. Tables and columns follow the baseline migration `0001_initial_schema`,
plus the `jobs` (background queue) and `webhook_deliveries` tables created by the Python migrations."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    String,
    Table,
    Text,
    TypeDecorator,
    func,
    select,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, object_session, relationship

from netdef_ci.db import utcnow
from netdef_ci.enums import FAILED_STATUSES, RUNNING_STATUSES, Status

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.clients.github import GithubCheck

Output = dict[str, str]
BigId = BigInteger().with_variant(Integer, "sqlite")


class Base(DeclarativeBase):
    # Index names ("index_<table>_on_<column>") so the ORM metadata matches the baseline migration.
    metadata = MetaData(naming_convention={"ix": "index_%(table_name)s_on_%(column_0_name)s"})


class StatusType(TypeDecorator[Status]):
    """Integer column exposed as `Status` (stable integer values)."""

    impl = Integer
    cache_ok = True

    def process_bind_param(self, value: Any, dialect: Any) -> int | None:
        return None if value is None else int(value)

    def process_result_value(self, value: Any, dialect: Any) -> Status | None:
        return None if value is None else Status(value)


def _session(obj: Any) -> Session:
    session = object_session(obj)
    if session is None:  # pragma: no cover - programming error
        raise RuntimeError(f"{type(obj).__name__} is not attached to a session")
    return session


def _ts() -> Mapped[datetime]:
    return mapped_column(DateTime, nullable=False, default=utcnow)


def _ts_updated() -> Mapped[datetime]:
    return mapped_column(DateTime, nullable=False, default=utcnow, onupdate=utcnow)


audit_retries_ci_jobs = Table(
    "audit_retries_ci_jobs",
    Base.metadata,
    Column("ci_job_id", BigId, ForeignKey("ci_jobs.id"), index=True),
    Column("audit_retry_id", BigId, ForeignKey("audit_retries.id"), index=True),
)


class Organization(Base):
    __tablename__ = "organizations"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    contact_email: Mapped[str | None] = mapped_column(String)
    contact_name: Mapped[str | None] = mapped_column(String)
    url: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()

    def __repr__(self) -> str:
        return (
            f"Organization id: {self.id}, name: {self.name}, contact_email: {self.contact_email}, "
            f"contact_name: {self.contact_name}, url: {self.url} "
            f"created_at: {self.created_at}, updated_at: {self.updated_at}"
        )


class GithubUser(Base):
    __tablename__ = "github_users"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    github_login: Mapped[str | None] = mapped_column(String)
    github_username: Mapped[str | None] = mapped_column(String)
    github_email: Mapped[str | None] = mapped_column(String)
    github_id: Mapped[int | None] = mapped_column(Integer, unique=True, index=True)
    github_organization: Mapped[str | None] = mapped_column(String)
    github_type: Mapped[str | None] = mapped_column(String)
    organization_name: Mapped[str | None] = mapped_column(String)
    organization_url: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    organization_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("organizations.id"), index=True)
    slack_username: Mapped[str | None] = mapped_column(String)
    slack_id: Mapped[str | None] = mapped_column(String)

    organization: Mapped[Organization | None] = relationship()


class StageConfiguration(Base):
    __tablename__ = "stage_configurations"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    bamboo_stage_name: Mapped[str] = mapped_column(String, nullable=False)
    github_check_run_name: Mapped[str] = mapped_column(String, nullable=False)
    start_in_progress: Mapped[bool | None] = mapped_column(Boolean, default=False)
    can_retry: Mapped[bool | None] = mapped_column(Boolean, default=True)
    position: Mapped[int | None] = mapped_column(Integer)
    mandatory: Mapped[bool | None] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()


class PullRequest(Base):
    __tablename__ = "pull_requests"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    author: Mapped[str] = mapped_column(String, nullable=False)
    github_pr_id: Mapped[int] = mapped_column(Integer, nullable=False)
    branch_name: Mapped[str] = mapped_column(String, nullable=False)
    repository: Mapped[str] = mapped_column(String, nullable=False)
    plan: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    github_user_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("github_users.id"), index=True)

    # NOTE: a Plan row belongs to ONE pull request at a time
    # (`plans.pull_request_id`); assigning plans to a PR steals them from the previous one.
    plans: Mapped[list[Plan]] = relationship(back_populates="pull_request", foreign_keys="Plan.pull_request_id")
    check_suites: Mapped[list[CheckSuite]] = relationship(
        back_populates="pull_request", order_by="CheckSuite.id", foreign_keys="CheckSuite.pull_request_id"
    )

    def last_check_suite(self) -> CheckSuite | None:
        return (
            _session(self)
            .scalars(
                select(CheckSuite).where(CheckSuite.pull_request_id == self.id).order_by(CheckSuite.id.desc()).limit(1)
            )
            .first()
        )

    def current_execution_by_plan(self, plan: Plan | None) -> CheckSuite | None:
        stmt = select(CheckSuite).where(CheckSuite.pull_request_id == self.id)
        stmt = (
            stmt.where(CheckSuite.plan_id == (plan.id if plan is not None else None))
            if plan
            else stmt.where(CheckSuite.plan_id.is_(None))
        )
        return _session(self).scalars(stmt.order_by(CheckSuite.id.desc()).limit(1)).first()

    def current_execution(self, check_suite: CheckSuite) -> bool:
        current = self.current_execution_by_plan(check_suite.plan)
        return current is not None and current.id == check_suite.id

    def is_finished(self) -> bool:
        last = self.last_check_suite()
        if last is None:
            return True
        if self.plans:
            return all((cs := self.current_execution_by_plan(p)) is not None and cs.is_finished() for p in self.plans)
        return last.is_finished()

    @staticmethod
    def unique_repository_names(session: Session) -> list[str]:
        return list(session.scalars(select(PullRequest.repository).distinct()))


class Plan(Base):
    __tablename__ = "plans"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    bamboo_ci_plan_name: Mapped[str] = mapped_column(String, nullable=False)
    github_repo_name: Mapped[str] = mapped_column(String, nullable=False, default="0")
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    check_suite_id: Mapped[int | None] = mapped_column(BigId, index=True)  # unused column
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)
    name: Mapped[str] = mapped_column(String, nullable=False, default="")

    pull_request: Mapped[PullRequest | None] = relationship(back_populates="plans", foreign_keys=[pull_request_id])


class CheckSuite(Base):
    __tablename__ = "check_suites"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    author: Mapped[str] = mapped_column(String, nullable=False)
    commit_sha_ref: Mapped[str] = mapped_column(String, nullable=False)
    base_sha_ref: Mapped[str] = mapped_column(String, nullable=False)
    bamboo_ci_ref: Mapped[str | None] = mapped_column(String)
    merge_branch: Mapped[str | None] = mapped_column(String)
    work_branch: Mapped[str | None] = mapped_column(String)
    details: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)
    re_run: Mapped[bool | None] = mapped_column(Boolean, default=False)
    retry: Mapped[int | None] = mapped_column(Integer, default=0)
    sync: Mapped[bool | None] = mapped_column(Boolean, default=False)
    github_user_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("github_users.id"), index=True)
    # The DB has an FK to stages.id; it is not declared here to keep metadata free of an FK cycle.
    stopped_in_stage_id: Mapped[int | None] = mapped_column(BigId, index=True)
    cancelled_previous_check_suite_id: Mapped[int | None] = mapped_column(
        BigId, ForeignKey("check_suites.id"), index=True
    )
    plan_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("plans.id"), index=True)

    pull_request: Mapped[PullRequest | None] = relationship(
        back_populates="check_suites", foreign_keys=[pull_request_id]
    )
    plan: Mapped[Plan | None] = relationship(foreign_keys=[plan_id])
    stages: Mapped[list[Stage]] = relationship(
        back_populates="check_suite", order_by="Stage.id", foreign_keys="Stage.check_suite_id"
    )
    ci_jobs: Mapped[list[CiJob]] = relationship(
        back_populates="check_suite", order_by="CiJob.id", foreign_keys="CiJob.check_suite_id"
    )
    audit_retries: Mapped[list[AuditRetry]] = relationship(back_populates="check_suite")

    def is_running(self) -> bool:
        return (
            _session(self).scalar(
                select(func.count())
                .select_from(Stage)
                .where(Stage.check_suite_id == self.id, Stage.status.in_(list(RUNNING_STATUSES)))
            )
            or 0
        ) > 0

    def is_finished(self) -> bool:
        return not self.is_running()

    def is_in_progress(self) -> bool:
        return not self.is_finished()

    def running_jobs(self) -> list[CiJob]:
        return list(
            _session(self).scalars(
                select(CiJob)
                .where(CiJob.check_suite_id == self.id, CiJob.status.in_(list(RUNNING_STATUSES)))
                .order_by(CiJob.id)
            )
        )

    def stages_failure(self) -> list[Stage]:
        stmt = (
            select(Stage)
            .join(CiJob, CiJob.stage_id == Stage.id)
            .where(Stage.check_suite_id == self.id, CiJob.status.in_([Status.CANCELLED, Status.FAILURE]))
            .order_by(Stage.id)
        )
        seen: dict[int, Stage] = {}
        for stage in _session(self).scalars(stmt):
            seen.setdefault(stage.id, stage)
        return list(seen.values())

    def last_job_updated_at(self) -> datetime | None:
        return _session(self).scalar(select(func.max(CiJob.updated_at)).where(CiJob.check_suite_id == self.id))


class Stage(Base):
    __tablename__ = "stages"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    check_ref: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
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
        return bool(self.jobs_with(*RUNNING_STATUSES))

    def is_finished(self) -> bool:
        return not self.jobs_with(*RUNNING_STATUSES)

    def suffix(self) -> str:
        return self.name.split(" - ")[-1]

    def full_name(self) -> str:
        return f"[CI] {self.name}"

    def update_execution_time(self) -> None:
        started, finished = _audit_pair(self, "Stage")
        if started is None or finished is None:
            return
        self.execution_time = int((finished.created_at - started.created_at).total_seconds())
        _session(self).commit()

    # --- transitions (port of lib/models/stage.rb) ---------------------------------------------
    def enqueue(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        check_run = github.create(self.full_name())
        github.queued(check_run["id"], output or {})
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
        # Finishing a stage creates a fresh check run and completes it.
        check_run = github.create(self.full_name())
        call(check_run["id"], output or {})
        self._record(status, agent, check_ref=str(check_run["id"]))
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
        from netdef_ci.config import get_settings

        settings = get_settings()
        in_progress = self.jobs_with(Status.IN_PROGRESS)
        total = len(self.all_jobs())
        header = f":arrow_right: Jobs in progress: {len(in_progress)}/{total}\n\n"
        lines = "\n".join(f"- **{job.name}** -> {settings.browse_url(job.job_ref)}\n" for job in in_progress)
        suite = self.check_suite
        url = settings.browse_url(suite.bamboo_ci_ref if suite else None)
        return {"title": f"{self.name} summary", "summary": f"{header}{lines}\nDetails at [{url}]({url})"}


class CiJob(Base):
    __tablename__ = "ci_jobs"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    job_ref: Mapped[str | None] = mapped_column(String)
    check_ref: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    check_suite_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("check_suites.id"), index=True)
    retry: Mapped[int | None] = mapped_column(Integer, default=0)
    parent_stage_id: Mapped[int | None] = mapped_column(Integer)
    stage_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("stages.id"), index=True)
    execution_time: Mapped[int | None] = mapped_column(Integer)
    summary: Mapped[str | None] = mapped_column(String)

    check_suite: Mapped[CheckSuite | None] = relationship(back_populates="ci_jobs", foreign_keys=[check_suite_id])
    stage: Mapped[Stage | None] = relationship(back_populates="jobs", foreign_keys=[stage_id])
    topotest_failures: Mapped[list[TopotestFailure]] = relationship(order_by="TopotestFailure.id")
    audit_retries: Mapped[list[AuditRetry]] = relationship(secondary=audit_retries_ci_jobs, back_populates="ci_jobs")

    @property
    def state(self) -> Status:
        return Status(self.status)

    def is_finished(self) -> bool:
        return self.state not in RUNNING_STATUSES

    def update_execution_time(self) -> None:
        started, finished = _audit_pair(self, "CiJob")
        if started is None or finished is None:
            return
        duration = (finished.created_at - started.created_at).total_seconds()
        self.execution_time = int(duration)
        _session(self).commit()
        from netdef_ci import metrics

        stage_name = self.stage.configuration.bamboo_stage_name if self.stage and self.stage.configuration else None
        metrics.CI_JOB_DURATION.labels(stage=stage_name or "unknown", status=self.state.label).observe(duration)

    def create_check_run(self, agent: str = "Github") -> None:
        self._record(Status.QUEUED, agent)

    def enqueue(self, _github: GithubCheck | None = None, _output: Output | None = None, agent: str = "Github") -> None:
        self._record(Status.QUEUED, agent)

    def in_progress(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._transition(github, Status.IN_PROGRESS, github.in_progress, output, agent)

    def cancelled(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._transition(github, Status.CANCELLED, github.cancelled, output, agent)

    def failure(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._transition(github, Status.FAILURE, github.failure, output, agent)

    def success(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._transition(github, Status.SUCCESS, github.success, output, agent)

    def skipped(self, github: GithubCheck, output: Output | None = None, agent: str = "Github") -> None:
        self._transition(github, Status.SKIPPED, github.skipped, output, agent)

    def _transition(self, github: GithubCheck, status: Status, call: Any, output: Output | None, agent: str) -> None:
        # Jobs only own a GitHub check run when `check_ref` is set (the app never creates one for jobs).
        if self.check_ref is not None:
            call(self.check_ref, output or {})
        self._record(status, agent)

    def _record(self, status: Status, agent: str) -> None:
        session = _session(self)
        session.add(AuditStatus(auditable_type="CiJob", auditable_id=self.id, status=status, agent=agent))
        self.status = status
        session.commit()


def _audit_pair(obj: CiJob | Stage, kind: str) -> tuple[AuditStatus | None, AuditStatus | None]:
    session = _session(obj)
    base = select(AuditStatus).where(AuditStatus.auditable_type == kind, AuditStatus.auditable_id == obj.id)
    started = session.scalars(
        base.where(AuditStatus.status == Status.IN_PROGRESS).order_by(AuditStatus.id).limit(1)
    ).first()
    finished = session.scalars(
        base.where(AuditStatus.status.in_([Status.SUCCESS, Status.FAILURE])).order_by(AuditStatus.id).limit(1)
    ).first()
    return started, finished


class TopotestFailure(Base):
    __tablename__ = "topotest_failures"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    test_suite: Mapped[str] = mapped_column(String, nullable=False)
    test_case: Mapped[str] = mapped_column(String, nullable=False)
    message: Mapped[str] = mapped_column(String, nullable=False)
    execution_time: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    ci_job_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("ci_jobs.id"), index=True)

    def to_dict(self) -> dict[str, Any]:
        return {
            "suite": self.test_suite,
            "case": self.test_case,
            "message": self.message,
            "execution_time": self.execution_time,
        }


class AuditStatus(Base):
    __tablename__ = "audit_statuses"
    __table_args__ = (
        Index("index_audit_statuses_on_auditable_type_and_auditable_id", "auditable_type", "auditable_id"),
    )

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    status: Mapped[Status] = mapped_column(StatusType, nullable=False, default=Status.QUEUED)
    agent: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    auditable_type: Mapped[str] = mapped_column(String, nullable=False)
    auditable_id: Mapped[int] = mapped_column(BigId, nullable=False)


class AuditRetry(Base):
    __tablename__ = "audit_retries"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    github_username: Mapped[str | None] = mapped_column(String)
    github_id: Mapped[str | None] = mapped_column(String)
    github_type: Mapped[str | None] = mapped_column(String)
    retry_type: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    check_suite_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("check_suites.id"), index=True)
    github_user_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("github_users.id"), index=True)

    check_suite: Mapped[CheckSuite | None] = relationship(back_populates="audit_retries")
    ci_jobs: Mapped[list[CiJob]] = relationship(secondary=audit_retries_ci_jobs, back_populates="audit_retries")


class PullRequestSubscription(Base):
    __tablename__ = "pull_request_subscriptions"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    slack_user_id: Mapped[str] = mapped_column(String, nullable=False)
    rule: Mapped[str] = mapped_column(String, nullable=False)
    target: Mapped[str] = mapped_column(String, nullable=False)
    notification: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()
    pull_request_id: Mapped[int | None] = mapped_column(BigId, ForeignKey("pull_requests.id"), index=True)


class Job(Base):
    """Background job (PostgreSQL-backed queue)."""

    __tablename__ = "jobs"
    __table_args__ = (
        Index("index_jobs_on_queue_and_run_at", "queue", "run_at"),
        Index("index_jobs_on_handler_and_dedupe_key", "handler", "dedupe_key"),
    )

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    queue: Mapped[str | None] = mapped_column(String)
    handler: Mapped[str] = mapped_column(String, nullable=False)
    args: Mapped[list[Any]] = mapped_column(JSON, nullable=False, default=list)
    priority: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=5)
    run_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow)
    locked_at: Mapped[datetime | None] = mapped_column(DateTime)
    locked_by: Mapped[str | None] = mapped_column(String)
    failed_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_error: Mapped[str | None] = mapped_column(Text)
    dedupe_key: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = _ts()
    updated_at: Mapped[datetime] = _ts_updated()


class WebhookDelivery(Base):
    __tablename__ = "webhook_deliveries"

    id: Mapped[int] = mapped_column(BigId, primary_key=True)
    delivery_id: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    event: Mapped[str | None] = mapped_column(String)
    received_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow, index=True)
