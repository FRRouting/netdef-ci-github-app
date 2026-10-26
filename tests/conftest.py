#  SPDX-License-Identifier: BSD-2-Clause
#
#  conftest.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import os
import shutil
import tempfile
from collections.abc import Iterator
from pathlib import Path

# --- environment must be prepared before netdef_ci reads its settings -----------------------------------------------
_TMP = Path(tempfile.mkdtemp(prefix="netdef-ci-tests-"))
os.environ.update(
    {
        "NETDEF_ENV": "test",
        "WEBHOOK_SECRET": "test-secret",
        "PROMETHEUS_MULTIPROC_DIR": str(_TMP / "prom"),
        "CI_URL": "ci.example.test",
        "SLACK_BOT_URL": "https://slack-bot.example.test",
        "SLACK_BOT_USERNAME": "slackbot",
        "SLACK_BOT_PASSWORD": "slackpass",
        "BAMBOO_USERNAME": "bamboo",
        "BAMBOO_PASSWORD": "bamboopass",
        "METRICS_USERNAME": "metrics",
        "METRICS_PASSWORD": "metricspass",
        "HOME": str(_TMP),  # no ~/.netrc from the developer machine
    }
)
os.environ.pop("DATABASE_URL", None)

import pytest  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import rsa  # noqa: E402
from sqlalchemy import text  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from netdef_ci import container, db  # noqa: E402
from netdef_ci.config import get_settings, reset_settings_cache  # noqa: E402
from netdef_ci.models import Base  # noqa: E402
from tests.fakes import FakeBamboo, FakeGithub, FakeSlack  # noqa: E402

TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL") or f"sqlite:///{_TMP / 'test.db'}"
IS_PG = TEST_DATABASE_URL.startswith("postgresql")


@pytest.fixture(scope="session")
def rsa_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture(scope="session", autouse=True)
def _settings_env(rsa_key: rsa.RSAPrivateKey) -> Iterator[None]:
    pem = _TMP / "app.pem"
    pem.write_bytes(
        rsa_key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        )
    )
    apps = _TMP / "github_apps.toml"
    apps.write_text(f'[[github_apps]]\nlogin = "12345"\ncert = "{pem}"\nrepo = "org/repo"\n')
    os.environ["GITHUB_APPS_FILE"] = str(apps)
    os.environ["DATABASE_URL"] = TEST_DATABASE_URL
    reset_settings_cache()
    yield
    shutil.rmtree(_TMP, ignore_errors=True)


@pytest.fixture(scope="session")
def engine(_settings_env: None):
    engine = db.init_engine(TEST_DATABASE_URL, force=True)
    if IS_PG:
        from alembic import command
        from alembic.config import Config

        with engine.begin() as conn:
            conn.execute(text("DROP SCHEMA public CASCADE"))
            conn.execute(text("CREATE SCHEMA public"))
        root = Path(__file__).resolve().parents[1]
        config = Config(str(root / "alembic.ini"))
        config.set_main_option("script_location", str(root / "migrations"))
        config.set_main_option("sqlalchemy.url", TEST_DATABASE_URL.replace("%", "%%"))
        command.upgrade(config, "head")
    else:
        Base.metadata.create_all(engine)
    yield engine
    db.dispose_engine()


@pytest.fixture
def session(engine) -> Iterator[Session]:
    """Clean tables for every test (TRUNCATE on PostgreSQL, DELETE on SQLite)."""
    with engine.begin() as conn:
        names = [t.name for t in reversed(Base.metadata.sorted_tables)]
        if IS_PG:
            conn.execute(text("TRUNCATE " + ", ".join(f'"{n}"' for n in names) + " RESTART IDENTITY CASCADE"))
        else:
            for name in names:
                conn.execute(text(f'DELETE FROM "{name}"'))
    with db.new_session() as session:
        yield session


@pytest.fixture
def github() -> FakeGithub:
    return FakeGithub()


@pytest.fixture
def bamboo() -> FakeBamboo:
    return FakeBamboo()


@pytest.fixture
def slack() -> FakeSlack:
    return FakeSlack()


@pytest.fixture
def clients(github: FakeGithub, bamboo: FakeBamboo, slack: FakeSlack) -> Iterator[None]:
    container.reset()
    container.override(bamboo=bamboo, slack=slack, github_factory=lambda _suite: github)
    yield
    container.reset()


@pytest.fixture
def settings():
    return get_settings()
