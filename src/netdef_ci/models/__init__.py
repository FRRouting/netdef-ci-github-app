#  SPDX-License-Identifier: BSD-2-Clause
#
#  models/__init__.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""SQLAlchemy models, one module per table (port of lib/models/). Tables and columns follow the baseline
migration `0001_initial_schema`, plus the `jobs` and `webhook_deliveries` tables of the Python migrations.
Importing the package registers every model, so string references between them resolve."""

from __future__ import annotations

from netdef_ci.models.audit_retry import AuditRetry
from netdef_ci.models.audit_status import AuditStatus
from netdef_ci.models.base import Base, Output
from netdef_ci.models.check_suite import CheckSuite
from netdef_ci.models.ci_job import CiJob
from netdef_ci.models.github_user import GithubUser
from netdef_ci.models.job import Job
from netdef_ci.models.organization import Organization
from netdef_ci.models.plan import Plan
from netdef_ci.models.pull_request import PullRequest, find_pull_request
from netdef_ci.models.pull_request_subscription import PullRequestSubscription
from netdef_ci.models.stage import Stage
from netdef_ci.models.stage_configuration import StageConfiguration
from netdef_ci.models.topotest_failure import TopotestFailure
from netdef_ci.models.webhook_delivery import WebhookDelivery

__all__ = [
    "AuditRetry",
    "AuditStatus",
    "Base",
    "CheckSuite",
    "CiJob",
    "GithubUser",
    "Job",
    "Organization",
    "Output",
    "Plan",
    "PullRequest",
    "PullRequestSubscription",
    "Stage",
    "StageConfiguration",
    "TopotestFailure",
    "WebhookDelivery",
    "find_pull_request",
]
