"""Initial schema: the domain tables of the CI app.

On a database that already has these tables nothing is changed, so the revision can simply be applied (or stamped). On an empty database the tables are created with the same layout.

Revision ID: 0001_initial_schema
Revises:
"""

import sqlalchemy as sa
from alembic import op

revision = "0001_initial_schema"
down_revision = None
branch_labels = None
depends_on = None


def _ts():
    return [
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    ]


def upgrade() -> None:
    bind = op.get_bind()
    existing = set(sa.inspect(bind).get_table_names())

    def create(name: str, *columns: sa.Column, **kwargs) -> None:
        if name not in existing:
            op.create_table(name, *columns, **kwargs)

    big = sa.BigInteger()
    create(
        "organizations",
        sa.Column("id", big, primary_key=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("contact_email", sa.String()),
        sa.Column("contact_name", sa.String()),
        sa.Column("url", sa.String()),
        *_ts(),
    )
    create(
        "github_users",
        sa.Column("id", big, primary_key=True),
        sa.Column("github_login", sa.String()),
        sa.Column("github_username", sa.String()),
        sa.Column("github_email", sa.String()),
        sa.Column("github_id", sa.Integer()),
        sa.Column("github_organization", sa.String()),
        sa.Column("github_type", sa.String()),
        sa.Column("organization_name", sa.String()),
        sa.Column("organization_url", sa.String()),
        *_ts(),
        sa.Column("organization_id", big, sa.ForeignKey("organizations.id")),
        sa.Column("slack_username", sa.String()),
        sa.Column("slack_id", sa.String()),
    )
    create(
        "stage_configurations",
        sa.Column("id", big, primary_key=True),
        sa.Column("bamboo_stage_name", sa.String(), nullable=False),
        sa.Column("github_check_run_name", sa.String(), nullable=False),
        sa.Column("start_in_progress", sa.Boolean(), server_default=sa.false()),
        sa.Column("can_retry", sa.Boolean(), server_default=sa.true()),
        sa.Column("position", sa.Integer()),
        sa.Column("mandatory", sa.Boolean(), server_default=sa.true()),
        *_ts(),
    )
    create(
        "pull_requests",
        sa.Column("id", big, primary_key=True),
        sa.Column("author", sa.String(), nullable=False),
        sa.Column("github_pr_id", sa.Integer(), nullable=False),
        sa.Column("branch_name", sa.String(), nullable=False),
        sa.Column("repository", sa.String(), nullable=False),
        sa.Column("plan", sa.String()),
        *_ts(),
        sa.Column("github_user_id", big, sa.ForeignKey("github_users.id")),
    )
    create(
        "plans",
        sa.Column("id", big, primary_key=True),
        sa.Column("bamboo_ci_plan_name", sa.String(), nullable=False),
        sa.Column("github_repo_name", sa.String(), nullable=False, server_default="0"),
        *_ts(),
        sa.Column("check_suite_id", big),
        sa.Column("pull_request_id", big, sa.ForeignKey("pull_requests.id")),
        sa.Column("name", sa.String(), nullable=False, server_default=""),
    )
    create(
        "check_suites",
        sa.Column("id", big, primary_key=True),
        sa.Column("author", sa.String(), nullable=False),
        sa.Column("commit_sha_ref", sa.String(), nullable=False),
        sa.Column("base_sha_ref", sa.String(), nullable=False),
        sa.Column("bamboo_ci_ref", sa.String()),
        sa.Column("merge_branch", sa.String()),
        sa.Column("work_branch", sa.String()),
        sa.Column("details", sa.String()),
        *_ts(),
        sa.Column("pull_request_id", big, sa.ForeignKey("pull_requests.id")),
        sa.Column("re_run", sa.Boolean(), server_default=sa.false()),
        sa.Column("retry", sa.Integer(), server_default="0"),
        sa.Column("sync", sa.Boolean(), server_default=sa.false()),
        sa.Column("github_user_id", big, sa.ForeignKey("github_users.id")),
        sa.Column("stopped_in_stage_id", big),
        sa.Column("cancelled_previous_check_suite_id", big, sa.ForeignKey("check_suites.id")),
        sa.Column("plan_id", big, sa.ForeignKey("plans.id")),
    )
    create(
        "stages",
        sa.Column("id", big, primary_key=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("status", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("check_ref", sa.String()),
        *_ts(),
        sa.Column("check_suite_id", big, sa.ForeignKey("check_suites.id")),
        sa.Column("stage_configuration_id", big, sa.ForeignKey("stage_configurations.id")),
        sa.Column("execution_time", sa.Integer()),
    )
    create(
        "ci_jobs",
        sa.Column("id", big, primary_key=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("status", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("job_ref", sa.String()),
        sa.Column("check_ref", sa.String()),
        *_ts(),
        sa.Column("check_suite_id", big, sa.ForeignKey("check_suites.id")),
        sa.Column("retry", sa.Integer(), server_default="0"),
        sa.Column("parent_stage_id", sa.Integer()),
        sa.Column("stage_id", big, sa.ForeignKey("stages.id")),
        sa.Column("execution_time", sa.Integer()),
        sa.Column("summary", sa.String()),
    )
    create(
        "topotest_failures",
        sa.Column("id", big, primary_key=True),
        sa.Column("test_suite", sa.String(), nullable=False),
        sa.Column("test_case", sa.String(), nullable=False),
        sa.Column("message", sa.String(), nullable=False),
        sa.Column("execution_time", sa.Integer(), nullable=False),
        *_ts(),
        sa.Column("ci_job_id", big, sa.ForeignKey("ci_jobs.id")),
    )
    create(
        "audit_statuses",
        sa.Column("id", big, primary_key=True),
        sa.Column("status", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("agent", sa.String()),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("auditable_type", sa.String(), nullable=False),
        sa.Column("auditable_id", big, nullable=False),
    )
    create(
        "audit_retries",
        sa.Column("id", big, primary_key=True),
        sa.Column("github_username", sa.String()),
        sa.Column("github_id", sa.String()),
        sa.Column("github_type", sa.String()),
        sa.Column("retry_type", sa.String()),
        *_ts(),
        sa.Column("check_suite_id", big, sa.ForeignKey("check_suites.id")),
        sa.Column("github_user_id", big, sa.ForeignKey("github_users.id")),
    )
    create(
        "audit_retries_ci_jobs",
        sa.Column("ci_job_id", big, sa.ForeignKey("ci_jobs.id")),
        sa.Column("audit_retry_id", big, sa.ForeignKey("audit_retries.id")),
    )
    create(
        "pull_request_subscriptions",
        sa.Column("id", big, primary_key=True),
        sa.Column("slack_user_id", sa.String(), nullable=False),
        sa.Column("rule", sa.String(), nullable=False),
        sa.Column("target", sa.String(), nullable=False),
        sa.Column("notification", sa.String()),
        *_ts(),
        sa.Column("pull_request_id", big, sa.ForeignKey("pull_requests.id")),
    )

    if "check_suites" not in existing:
        # circular references, added after both tables exist
        op.create_foreign_key(
            "fk_check_suites_stopped_in_stage", "check_suites", "stages", ["stopped_in_stage_id"], ["id"]
        )
        op.create_foreign_key("fk_plans_check_suite", "plans", "check_suites", ["check_suite_id"], ["id"])
        for table, columns in {
            "audit_retries": ["check_suite_id", "github_user_id"],
            "audit_retries_ci_jobs": ["audit_retry_id", "ci_job_id"],
            "check_suites": [
                "cancelled_previous_check_suite_id",
                "github_user_id",
                "plan_id",
                "pull_request_id",
                "stopped_in_stage_id",
            ],
            "ci_jobs": ["check_suite_id", "stage_id"],
            "github_users": ["organization_id"],
            "plans": ["check_suite_id", "pull_request_id"],
            "pull_request_subscriptions": ["pull_request_id"],
            "pull_requests": ["github_user_id"],
            "stages": ["check_suite_id", "stage_configuration_id"],
            "topotest_failures": ["ci_job_id"],
        }.items():
            for column in columns:
                op.create_index(f"index_{table}_on_{column}", table, [column])
        op.create_index(
            "index_audit_statuses_on_auditable_type_and_auditable_id",
            "audit_statuses",
            ["auditable_type", "auditable_id"],
        )
        op.create_index("index_github_users_on_github_id", "github_users", ["github_id"], unique=True)


def downgrade() -> None:
    raise RuntimeError("The initial schema cannot be downgraded: it holds the domain data.")
