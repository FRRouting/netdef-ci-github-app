#  SPDX-License-Identifier: BSD-2-Clause
#
#  test_align_md_tables.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("align_md_tables", ROOT / "scripts" / "align_md_tables.py")
assert _spec is not None and _spec.loader is not None
align = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(align)


def test_columns_are_padded_and_alignment_markers_kept() -> None:
    text = "intro\n\n| a | long header | n |\n|---|:-:|--:|\n| xyz | y | 10 |\n| `a\\|b` | centred |\n"
    assert align.align_text(text) == (
        "intro\n\n"
        "| a      | long header |  n |\n"
        "|--------|:-----------:|---:|\n"
        "| xyz    |      y      | 10 |\n"
        "| `a\\|b` |   centred   |    |\n"
    )


def test_code_blocks_and_plain_pipes_are_untouched() -> None:
    text = "```\n| a | b |\n|---|---|\n| c | d |\n```\nnot | a table\n"
    assert align.align_text(text) == text


def test_aligned_text_is_stable_and_wide_characters_count_twice() -> None:
    text = "| k | v |\n|---|---|\n| 日本 | x |\n| ab | y |\n"
    once = align.align_text(text)
    assert once.splitlines()[2] == "| 日本 | x |" and once.splitlines()[3] == "| ab   | y |"
    assert align.align_text(once) == once


def test_check_mode_reports_without_writing(tmp_path, capsys) -> None:
    doc = tmp_path / "doc.md"
    doc.write_text("| a | b |\n|---|---|\n| long | x |\n", encoding="utf-8")
    assert align.main(["--check", str(doc)]) == 1
    assert "misaligned tables in" in capsys.readouterr().out
    assert align.main([str(doc)]) == 0
    assert align.main(["--check", str(doc)]) == 0
    assert doc.read_text(encoding="utf-8").splitlines()[1] == "|------|---|"


def test_repository_documentation_is_aligned() -> None:
    files = align.markdown_files([str(ROOT / "README.md"), str(ROOT / "AGENTS.md"), str(ROOT / "doc")])
    assert files
    assert [f.name for f in files if align.align_text(f.read_text(encoding="utf-8")) != f.read_text("utf-8")] == []
