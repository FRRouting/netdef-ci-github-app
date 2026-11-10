#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/pull_request.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Pull request and its executions (port of lib/models/pull_request.rb)."""

from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import ForeignKey, Index, Integer, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column, relationship

from netdef_ci.models.base import Base, BigId, _session, _ts, _ts_updated
from netdef_ci.models.check_suite import CheckSuite

if TYPE_CHECKING:  # pragma: no cover
    from netdef_ci.models.plan import Plan


class PullRequest(Base):
    __tablename__ = "pull_requests"
    __table_args__ = (Index("index_pull_requests_on_github_pr_id_and_repository", "github_pr_id", "repository"),)

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


def find_pull_request(session: Session, github_pr_id: int | None, repository: str | None = None) -> PullRequest | None:
    """`PullRequest.find_by(github_pr_id:)`; the repository filter (when known) avoids matching a PR with the same
    number in another repository."""
    if github_pr_id is None:
        return None
    stmt = select(PullRequest).where(PullRequest.github_pr_id == github_pr_id)
    if repository:
        stmt = stmt.where(PullRequest.repository == repository)
    return session.scalars(stmt.order_by(PullRequest.id).limit(1)).first()
