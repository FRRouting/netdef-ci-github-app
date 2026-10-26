#  SPDX-License-Identifier: BSD-2-Clause
#
#  cli/main.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Command line: job worker, cron tasks (watch-dog, pr-bamboo-sync, single-sync), console (organizations/users)
and operational checks."""

from __future__ import annotations

import argparse
import signal
import sys
from collections.abc import Sequence
from pathlib import Path

from sqlalchemy import select

from netdef_ci import __version__
from netdef_ci.config import get_settings
from netdef_ci.db import init_engine, session_scope
from netdef_ci.logs import configure_logging
from netdef_ci.models import GithubUser, Organization


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="netdef_ci", description="NetDEF CI GitHub App")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command", required=True)

    worker = sub.add_parser("worker", help="run a background job worker (rake jobs:work)")
    worker.add_argument("--queues", default="", help="comma separated queue names; empty = every queue")

    sub.add_parser("watch-dog", help="reconcile every running check suite with Bamboo (cron)")
    sub.add_parser("pr-bamboo-sync", help="compare active GitHub checks with Bamboo and fix stale suites (cron)")
    single = sub.add_parser("single-sync", help="re-sync one Bamboo execution, e.g. PROJ-PLAN-123")
    single.add_argument("bamboo_ref")

    sub.add_parser("migrate", help="apply database migrations (alembic upgrade head)")
    stamp = sub.add_parser(
        "stamp-baseline", help="mark an existing database that already has the baseline schema as revision 0001"
    )
    stamp.add_argument("--revision", default="0001_initial_schema")
    sub.add_parser("check-config", help="validate configuration, GitHub App keys and database connectivity")
    sub.add_parser("purge-jobs", help="delete every pending background job (rake jobs:clear)")

    org = sub.add_parser("org", help="organizations").add_subparsers(dest="action", required=True)
    org.add_parser("find").add_argument("name")
    for action in ("create", "edit"):
        p = org.add_parser(action)
        p.add_argument("name")
        p.add_argument("--contact-email")
        p.add_argument("--contact-name")
        p.add_argument("--url")

    user = sub.add_parser("user", help="GitHub users").add_subparsers(dest="action", required=True)
    user.add_parser("find").add_argument("login")
    add = user.add_parser("add-to-org")
    add.add_argument("login")
    add.add_argument("organization")
    user.add_parser("remove-from-org").add_argument("login")
    slack = user.add_parser("link-slack")
    slack.add_argument("login")
    slack.add_argument("slack_user")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    configure_logging()
    handler = {
        "worker": _worker,
        "watch-dog": _watch_dog,
        "pr-bamboo-sync": _pr_bamboo_sync,
        "single-sync": _single_sync,
        "migrate": _migrate,
        "stamp-baseline": _stamp,
        "check-config": _check_config,
        "purge-jobs": _purge_jobs,
        "org": _org,
        "user": _user,
    }[args.command]
    return int(handler(args) or 0)


# ---------------------------------------------------------------------------- operations
def _worker(args: argparse.Namespace) -> int:
    from netdef_ci import metrics
    from netdef_ci.jobs import handlers  # noqa: F401 - registers handlers
    from netdef_ci.jobs.queue import Worker

    init_engine()
    metrics.cleanup_stale_metric_files()
    queues = [q.strip() for q in args.queues.split(",") if q.strip()] or None
    worker = Worker(queues=queues)
    signal.signal(signal.SIGTERM, lambda *_: worker.stop_event.set())
    signal.signal(signal.SIGINT, lambda *_: worker.stop_event.set())
    worker.run_forever()
    return 0


def _watch_dog(_: argparse.Namespace) -> int:
    from netdef_ci.services import tasks

    init_engine()
    with session_scope() as session:
        tasks.watch_dog(session)
    return 0


def _pr_bamboo_sync(_: argparse.Namespace) -> int:
    from netdef_ci.services import tasks

    init_engine()
    with session_scope() as session:
        tasks.pr_bamboo_sync(session)
    return 0


def _single_sync(args: argparse.Namespace) -> int:
    from netdef_ci.services import tasks

    init_engine()
    with session_scope() as session:
        return 0 if tasks.single_sync(session, args.bamboo_ref) else 1


def _alembic_config() -> object:
    from alembic.config import Config

    root = Path(__file__).resolve().parents[3]
    config = Config(str(root / "alembic.ini"))
    config.set_main_option("script_location", str(root / "migrations"))
    config.set_main_option("sqlalchemy.url", get_settings().database_url.replace("%", "%%"))
    return config


def _migrate(_: argparse.Namespace) -> int:
    from alembic import command
    from alembic.migration import MigrationContext
    from alembic.script import ScriptDirectory
    from sqlalchemy import create_engine

    config = _alembic_config()
    head = ScriptDirectory.from_config(config).get_current_head()  # type: ignore[arg-type]
    engine = create_engine(get_settings().database_url)
    try:
        with engine.connect() as connection:
            before = MigrationContext.configure(connection).get_current_revision()
    finally:
        engine.dispose()
    if before == head:
        print(f"database already at revision {head}")
        return 0
    command.upgrade(config, "head")  # type: ignore[arg-type]
    print(f"database upgraded from {before or 'empty'} to {head}")
    return 0


def _stamp(args: argparse.Namespace) -> int:
    from alembic import command

    command.stamp(_alembic_config(), args.revision)  # type: ignore[arg-type]
    return 0


def _purge_jobs(_: argparse.Namespace) -> int:
    from sqlalchemy import delete

    from netdef_ci.models import Job

    init_engine()
    with session_scope() as session:
        result = session.execute(delete(Job))
        session.commit()
        print(f"Removed {getattr(result, 'rowcount', 0)} job(s)")
    return 0


def _check_config(_: argparse.Namespace) -> int:
    from sqlalchemy import text

    settings = get_settings()
    problems: list[str] = []
    if not settings.webhook_secret.get_secret_value():
        problems.append("WEBHOOK_SECRET is empty")
    try:
        apps = settings.github_apps()
    except Exception as error:
        apps = []
        problems.append(f"GITHUB_APPS_FILE unreadable: {error}")
    if not apps:
        problems.append("no GitHub App configured (GITHUB_APPS_FILE)")
    for app in apps:
        if not Path(app.cert).is_file():
            problems.append(f"private key of app {app.login} not found: {app.cert}")
    if settings.bamboo_credentials() is None:
        problems.append("Bamboo credentials not found (BAMBOO_USERNAME/PASSWORD or ~/.netrc)")
    if not settings.slack_bot_url:
        print("warning: SLACK_BOT_URL not set; Slack notifications are disabled")
    try:
        init_engine()
        with session_scope() as session:
            session.execute(text("SELECT 1"))
    except Exception as error:
        problems.append(f"database unreachable: {type(error).__name__}")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    print("configuration OK" if not problems else f"{len(problems)} problem(s) found")
    return 1 if problems else 0


# ---------------------------------------------------------------------------- console (bin/console)
def _org(args: argparse.Namespace) -> int:
    init_engine()
    with session_scope() as session:
        found = session.scalars(select(Organization).where(Organization.name == args.name)).first()
        if args.action == "find":
            print(f"> {found!r}" if found else "Organization not found")
            return 0 if found else 1
        fields = {
            k: v
            for k, v in (("contact_email", args.contact_email), ("contact_name", args.contact_name), ("url", args.url))
            if v is not None
        }
        if args.action == "create":
            organization = Organization(name=args.name, **fields)
            session.add(organization)
            session.commit()
            print(f"Organization created: {organization!r}")
            return 0
        if found is None:
            print("Organization not found")
            return 1
        for key, value in fields.items():
            setattr(found, key, value)
        session.commit()
        print(f"Organization updated: {found!r}")
    return 0


def _user(args: argparse.Namespace) -> int:
    init_engine()
    with session_scope() as session:
        user = session.scalars(select(GithubUser).where(GithubUser.github_login == args.login)).first()
        if user is None:
            print("Github user not found")
            return 1
        if args.action == "find":
            print(
                f"> GithubUser id: {user.id}, login: {user.github_login}, organization_id: {user.organization_id}, slack_id: {user.slack_id}"
            )
        elif args.action == "add-to-org":
            organization = session.scalars(select(Organization).where(Organization.name == args.organization)).first()
            if organization is None:
                print("Organization not found")
                return 1
            user.organization_id = organization.id
            session.commit()
            print(f"Github user linked to organization: {user.github_login} -> {organization.name}")
        elif args.action == "remove-from-org":
            user.organization_id = None
            session.commit()
            print(f"Github user removed from organization: {user.github_login}")
        elif args.action == "link-slack":
            from netdef_ci.services import tasks

            user.slack_username = args.slack_user
            session.commit()
            tasks.slack_username_to_id(session, args.login, args.slack_user)
            print(f"Slack user linked to github user: {user.github_login} -> {args.slack_user}")
    return 0
