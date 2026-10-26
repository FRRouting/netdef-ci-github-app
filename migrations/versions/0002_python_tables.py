"""Tables used only by the Python implementation: background `jobs` queue and `webhook_deliveries`.

Revision ID: 0002_python_tables
Revises: 0001_ruby_baseline
"""

import sqlalchemy as sa
from alembic import op

revision = "0002_python_tables"
down_revision = "0001_ruby_baseline"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "jobs",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("queue", sa.String()),
        sa.Column("handler", sa.String(), nullable=False),
        sa.Column("args", sa.JSON(), nullable=False),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("max_attempts", sa.Integer(), nullable=False, server_default="5"),
        sa.Column("run_at", sa.DateTime(), nullable=False),
        sa.Column("locked_at", sa.DateTime()),
        sa.Column("locked_by", sa.String()),
        sa.Column("failed_at", sa.DateTime()),
        sa.Column("last_error", sa.Text()),
        sa.Column("dedupe_key", sa.String()),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_index("index_jobs_on_queue_and_run_at", "jobs", ["queue", "run_at"])
    op.create_index("index_jobs_on_handler_and_dedupe_key", "jobs", ["handler", "dedupe_key"])
    op.create_table(
        "webhook_deliveries",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("delivery_id", sa.String(), nullable=False, unique=True),
        sa.Column("event", sa.String()),
        sa.Column("received_at", sa.DateTime(), nullable=False),
    )
    op.create_index("index_webhook_deliveries_on_received_at", "webhook_deliveries", ["received_at"])


def downgrade() -> None:
    op.drop_table("webhook_deliveries")
    op.drop_table("jobs")
