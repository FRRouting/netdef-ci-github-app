#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_message_formatter.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

from netdef_ci.enums import Status
from netdef_ci.models import TopotestFailure
from netdef_ci.services.message_formatter import MAX_SUMMARY, MessageFormatter
from tests import factories as f


def test_summary_sections_and_counts(session, clients) -> None:
    w = f.World(session, statuses=(Status.IN_PROGRESS, Status.QUEUED))
    q = f.job(session, w.suite, w.build_stage, "queued job", Status.QUEUED, "R-Q")
    ok = f.job(session, w.suite, w.build_stage, "ok job", Status.SUCCESS, "R-OK")
    bad = f.job(session, w.suite, w.build_stage, "bad job", Status.FAILURE, "R-BAD")
    session.add(
        TopotestFailure(
            ci_job_id=bad.id, test_suite="suite", test_case="case", message="assert 1 == 2", execution_time=3
        )
    )
    session.commit()
    w.build_stage.name = "Tests"
    text = MessageFormatter().summary_basic_output(w.build_stage)
    assert ":arrow_right: Jobs queued: 1/4" in text
    assert "- **queued job** -> https://ci.example.test/browse/R-Q" in text
    assert ":arrow_right: Jobs in progress: 1/4" in text
    assert (
        ":heavy_check_mark: Jobs Success: 1/4" in text and "- **ok job** -> https://ci.example.test/browse/R-OK" in text
    )
    assert ":heavy_multiplication_x: Jobs Failure: 1/4" in text
    assert "- bad job -> https://ci.example.test/browse/R-BAD" in text
    assert ":no_entry_sign: suite case" in text and "assert 1 == 2" in text
    assert q and ok


def test_footer_links_and_timestamp(session, clients) -> None:
    w = f.World(session)
    text = MessageFormatter().summary_with_footer(w.build_stage, "https://ci/x")
    assert "\nDetails at [https://ci/x](https://ci/x).\n\nLast updated: " in text
    assert text.rstrip().endswith("UTC")


def test_checkout_stage_shows_job_summary(session, clients) -> None:
    w = f.World(session)
    w.build_job.status = Status.FAILURE
    w.build_job.summary = "line1<br>line2"
    session.commit()
    w.build_stage.name = "Source Checkout"
    msg = MessageFormatter().generate_message("Source Checkout", w.build_job)
    assert msg.endswith("```\nline1\nline2\n```\n")


def test_build_stage_shows_last_lines_of_error_log(session, clients, bamboo) -> None:
    w = f.World(session)
    bamboo.job_results[w.build_job.job_ref] = {
        "artifacts": {"artifact": [{"name": "ErrorLog", "link": {"href": "https://ci/log"}}]}
    }
    bamboo.logs["https://ci/log"] = "compile error"
    assert MessageFormatter().generate_message("Build", w.build_job).endswith("```\ncompile error\n```\n")
    bamboo.job_results[w.build_job.job_ref] = {"artifacts": {"artifact": []}}
    assert MessageFormatter().generate_message("Build", w.build_job).endswith("\n")


def test_output_is_truncated_to_github_limit(session, clients) -> None:
    w = f.World(session)
    for i in range(3000):
        f.job(session, w.suite, w.build_stage, "j" * 40 + str(i), Status.QUEUED, f"REF-{i}")
    assert len(MessageFormatter().summary_basic_output(w.build_stage)) == MAX_SUMMARY


def test_build_log_is_downloaded_once_and_cleared_when_the_job_runs_again(session, clients, bamboo, github) -> None:
    w = f.World(session)
    bamboo.job_results[w.build_job.job_ref] = {
        "artifacts": {"artifact": [{"name": "ErrorLog", "link": {"href": "https://ci/log"}}]}
    }
    bamboo.logs["https://ci/log"] = "compile error"
    MessageFormatter().generate_message("Build", w.build_job)
    assert w.build_job.build_log == "compile error"
    bamboo.logs["https://ci/log"] = "changed"  # not downloaded again while the job keeps its result
    assert MessageFormatter().generate_message("Build", w.build_job).endswith("```\ncompile error\n```\n")
    w.build_job.enqueue(github)
    assert w.build_job.build_log is None
    assert MessageFormatter().generate_message("Build", w.build_job).endswith("```\nchanged\n```\n")
