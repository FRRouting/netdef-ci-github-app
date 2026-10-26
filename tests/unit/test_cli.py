#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_cli.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import pytest
from sqlalchemy import select

from netdef_ci.cli.main import main
from netdef_ci.models import GithubUser, Job, Organization
from tests import factories as f


@pytest.fixture
def cli(session, clients, capsys):
    def run(*args: str) -> tuple[int, str]:
        code = main(list(args))
        session.expire_all()
        return code, capsys.readouterr().out

    return run


def test_organization_management(session, cli) -> None:
    assert cli("org", "find", "NetDEF") == (1, "Organization not found\n")
    code, out = cli("org", "create", "NetDEF", "--contact-name", "Rodrigo")
    assert code == 0 and "Organization created" in out and "contact_name: Rodrigo" in out
    assert cli("org", "edit", "NetDEF", "--contact-email", "ci@example.test", "--url", "https://example.test")[0] == 0
    organization = session.scalars(select(Organization)).one()
    assert (organization.contact_email, organization.contact_name, organization.url) == (
        "ci@example.test",
        "Rodrigo",
        "https://example.test",
    )
    assert cli("org", "edit", "Missing")[0] == 1
    assert cli("org", "find", "NetDEF")[0] == 0


def test_user_management(session, cli, slack) -> None:
    session.add(GithubUser(github_id=5, github_login="alice"))
    session.add(Organization(name="NetDEF"))
    session.commit()
    assert cli("user", "find", "ghost") == (1, "Github user not found\n")
    assert cli("user", "add-to-org", "alice", "Nope")[0] == 1
    assert cli("user", "add-to-org", "alice", "NetDEF")[0] == 0
    assert session.scalars(select(GithubUser)).one().organization_id is not None
    assert cli("user", "remove-from-org", "alice")[0] == 0
    assert session.scalars(select(GithubUser)).one().organization_id is None
    slack.user_ids["alice.s"] = "U9"
    assert cli("user", "link-slack", "alice", "alice.s")[0] == 0
    user = session.scalars(select(GithubUser)).one()
    assert (user.slack_username, user.slack_id) == ("alice.s", "U9")
    assert "login: alice" in cli("user", "find", "alice")[1]


def test_purge_jobs_and_check_config(session, cli, tmp_path) -> None:
    from netdef_ci.jobs import queue

    queue.enqueue(session, "x", [])
    assert cli("purge-jobs") == (0, "Removed 1 job(s)\n")
    assert session.scalars(select(Job)).all() == []
    code, out = cli("check-config")
    assert code == 0 and "configuration OK" in out
    assert f.next_id()
