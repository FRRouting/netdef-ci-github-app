#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_migrations.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Alembic migrations: empty database, Ruby-created database and parity with the ORM models."""

from __future__ import annotations

from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import create_engine, inspect, text

from netdef_ci.models import Base
from tests.conftest import IS_PG, TEST_DATABASE_URL

pytestmark = pytest.mark.skipif(not IS_PG, reason="needs PostgreSQL (TEST_DATABASE_URL)")

ROOT = Path(__file__).resolve().parents[2]
RUBY_TABLES = {
    "audit_retries",
    "audit_retries_ci_jobs",
    "audit_statuses",
    "check_suites",
    "ci_jobs",
    "github_users",
    "organizations",
    "plans",
    "pull_request_subscriptions",
    "pull_requests",
    "stage_configurations",
    "stages",
    "topotest_failures",
}


def config(url: str) -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url.replace("%", "%%"))
    return cfg


@pytest.fixture
def scratch_db(engine):
    """A throw-away database so the shared test schema is untouched."""
    name = "netdef_migration_test"
    with engine.connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
        conn.execute(text(f"DROP DATABASE IF EXISTS {name}"))
        conn.execute(text(f"CREATE DATABASE {name}"))
    url = engine.url.set(database=name).render_as_string(hide_password=False)
    yield url
    with engine.connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
        conn.execute(text(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)"))


def test_empty_database_gets_ruby_and_python_tables(scratch_db) -> None:
    command.upgrade(config(scratch_db), "head")
    eng = create_engine(scratch_db)
    tables = set(inspect(eng).get_table_names())
    assert tables >= RUBY_TABLES and {"jobs", "webhook_deliveries", "alembic_version"} <= tables
    assert "delayed_jobs" not in tables  # the Ruby queue table is not recreated
    fks = {(fk["referred_table"]) for fk in inspect(eng).get_foreign_keys("check_suites")}
    assert {"stages", "plans", "pull_requests", "github_users", "check_suites"} <= fks
    eng.dispose()


def test_models_and_migrations_describe_the_same_schema(scratch_db) -> None:
    command.upgrade(config(scratch_db), "head")
    eng = create_engine(scratch_db)
    with eng.connect() as conn:
        diffs = compare_metadata(MigrationContext.configure(conn, opts={"compare_type": False}), Base.metadata)
    eng.dispose()
    # only differences accepted on purpose: the FKs that would make the ORM metadata circular, server defaults
    unexpected = [d for d in diffs if not _accepted(d)]
    assert unexpected == [], unexpected


def _accepted(diff) -> bool:
    """Accepted differences: foreign keys that are intentionally not declared in the ORM (they would make the metadata
    circular: check_suites <-> stages and plans <-> check_suites)."""
    if isinstance(diff, list):
        return all(_accepted(d) for d in diff)
    return diff[0] in ("add_fk", "remove_fk")


def test_database_created_by_the_ruby_app_is_adopted_without_changes(scratch_db) -> None:
    cfg = config(scratch_db)
    command.upgrade(cfg, "0001_ruby_baseline")
    eng = create_engine(scratch_db)
    with eng.begin() as conn:  # simulate production data + the Ruby bookkeeping
        conn.execute(
            text(
                "INSERT INTO pull_requests (author, github_pr_id, branch_name, repository, created_at, updated_at) VALUES ('a', 1, 'b', 'o/r', now(), now())"
            )
        )
        conn.execute(text("DELETE FROM alembic_version"))
    command.stamp(cfg, "0001_ruby_baseline")  # `python -m netdef_ci stamp-ruby-schema`
    command.upgrade(cfg, "head")
    with eng.connect() as conn:
        assert conn.execute(text("SELECT count(*) FROM pull_requests")).scalar() == 1
        assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar() == "0002_python_tables"
    assert {"jobs", "webhook_deliveries"} <= set(inspect(eng).get_table_names())
    eng.dispose()


def test_baseline_over_existing_tables_is_idempotent(scratch_db) -> None:
    cfg = config(scratch_db)
    command.upgrade(cfg, "0001_ruby_baseline")
    eng = create_engine(scratch_db)
    with eng.begin() as conn:
        conn.execute(text("DELETE FROM alembic_version"))
    command.upgrade(cfg, "head")  # baseline sees every table and skips creation
    eng.dispose()


def test_python_migration_downgrade(scratch_db) -> None:
    cfg = config(scratch_db)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "0001_ruby_baseline")
    eng = create_engine(scratch_db)
    assert "jobs" not in set(inspect(eng).get_table_names())
    eng.dispose()
    assert TEST_DATABASE_URL
