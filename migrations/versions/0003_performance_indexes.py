"""Indexes for the lookups done on every Bamboo callback, webhook and metrics scrape, and the `ci_jobs.build_log`
column that caches the tail of a failed build log.

On PostgreSQL the indexes are built with CREATE INDEX CONCURRENTLY, so the migration does not block writes on the
large `ci_jobs` / `check_suites` tables while it runs.

Revision ID: 0003_performance_indexes
Revises: 0002_python_tables
"""

import sqlalchemy as sa
from alembic import op

revision = "0003_performance_indexes"
down_revision = "0002_python_tables"
branch_labels = None
depends_on = None

# (index name, table, columns, PostgreSQL operator classes)
INDEXES: list[tuple[str, str, list[str], dict[str, str]]] = [
    ("index_ci_jobs_on_job_ref", "ci_jobs", ["job_ref"], {}),
    ("index_ci_jobs_on_updated_at", "ci_jobs", ["updated_at"], {}),
    ("index_check_suites_on_bamboo_ci_ref", "check_suites", ["bamboo_ci_ref"], {}),
    # text_pattern_ops serves both `=` and the prefix match of `ci:rerun #<short sha>`.
    (
        "index_check_suites_on_commit_sha_ref",
        "check_suites",
        ["commit_sha_ref"],
        {"commit_sha_ref": "text_pattern_ops"},
    ),
    ("index_stages_on_check_ref", "stages", ["check_ref"], {}),
    ("index_stages_on_updated_at", "stages", ["updated_at"], {}),
    ("index_pull_requests_on_github_pr_id_and_repository", "pull_requests", ["github_pr_id", "repository"], {}),
    ("index_plans_on_github_repo_name", "plans", ["github_repo_name"], {}),
    ("index_github_users_on_github_login", "github_users", ["github_login"], {}),
    ("index_pull_request_subscriptions_on_target", "pull_request_subscriptions", ["target"], {}),
]


def upgrade() -> None:
    op.add_column("ci_jobs", sa.Column("build_log", sa.Text()))
    postgresql = op.get_bind().dialect.name == "postgresql"
    if not postgresql:
        for name, table, columns, _ops in INDEXES:
            op.create_index(name, table, columns, if_not_exists=True)
        return
    # CREATE INDEX CONCURRENTLY cannot run inside a transaction.
    with op.get_context().autocommit_block():
        for name, table, columns, ops in INDEXES:
            op.create_index(name, table, columns, postgresql_concurrently=True, postgresql_ops=ops, if_not_exists=True)


def downgrade() -> None:
    for name, table, _columns, _ops in reversed(INDEXES):
        op.drop_index(name, table_name=table, if_exists=True)
    op.drop_column("ci_jobs", "build_log")
