#!/usr/bin/env python3
#  SPDX-License-Identifier: BSD-2-Clause
#
#  align_md_tables.py
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

"""Align the columns of every Markdown table (GitHub-flavoured pipe tables).

    python scripts/align_md_tables.py                 # rewrite README.md, AGENTS.md and doc/*.md in place
    python scripts/align_md_tables.py --check         # only report misaligned files (exit 1 if any)
    python scripts/align_md_tables.py doc/07-design-notes.md

Cells are padded to the widest cell of their column (display width, so wide characters count twice), the separator
row is rebuilt (no inner spaces, as in the existing docs) keeping its `:---`, `:---:` and `---:` markers, and
centred/right-aligned columns are padded accordingly. Tables inside fenced code blocks are left untouched; escaped
pipes (`\\|`) stay inside their cell."""

from __future__ import annotations

import argparse
import re
import sys
import unicodedata
from pathlib import Path

DEFAULT_TARGETS = ("README.md", "AGENTS.md", "doc")
SEPARATOR_CELL = re.compile(r"^\s*:?-+:?\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def split_row(line: str) -> list[str]:
    """Cells of a table row, splitting on pipes that are not escaped."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    cells, current, escaped = [], "", False
    for char in body:
        if char == "|" and not escaped:
            cells.append(current.strip())
            current = ""
        else:
            current += char
        escaped = char == "\\" and not escaped
    cells.append(current.strip())
    return cells


def is_table_row(line: str) -> bool:
    return line.lstrip().startswith("|")


def is_separator(line: str) -> bool:
    cells = split_row(line)
    return is_table_row(line) and bool(cells) and all(SEPARATOR_CELL.match(cell) for cell in cells)


def alignment(cell: str) -> str:
    cell = cell.strip()
    if cell.startswith(":") and cell.endswith(":"):
        return "center"
    if cell.endswith(":"):
        return "right"
    return "left"


def pad(text: str, width: int, align: str) -> str:
    missing = width - display_width(text)
    if align == "right":
        return " " * missing + text
    if align == "center":
        left = missing // 2
        return " " * left + text + " " * (missing - left)
    return text + " " * missing


def separator(width: int, align: str) -> str:
    if align == "center":
        return ":" + "-" * (width - 2) + ":"
    if align == "right":
        return "-" * (width - 1) + ":"
    return "-" * width


def format_table(lines: list[str]) -> list[str]:
    indent = lines[0][: len(lines[0]) - len(lines[0].lstrip())]
    rows = [split_row(line) for line in lines]
    columns = max(len(row) for row in rows)
    rows = [row + [""] * (columns - len(row)) for row in rows]
    aligns = [alignment(cell) for cell in rows[1]]
    widths = [1] * columns
    for index, row in enumerate(rows):
        if index == 1:
            continue
        for column, cell in enumerate(row):
            widths[column] = max(widths[column], display_width(cell))
    formatted = []
    for index, row in enumerate(rows):
        if index == 1:  # the separator spans the cell padding too: |:-----:|------|
            formatted.append(indent + "|" + "|".join(separator(widths[c] + 2, aligns[c]) for c in range(columns)) + "|")
        else:
            cells = [pad(cell, widths[c], aligns[c]) for c, cell in enumerate(row)]
            formatted.append(indent + "| " + " | ".join(cells) + " |")
    return formatted


def align_text(text: str) -> str:
    lines = text.split("\n")
    output: list[str] = []
    in_fence = False
    index = 0
    while index < len(lines):
        line = lines[index]
        if FENCE.match(line):
            in_fence = not in_fence
        if (
            not in_fence
            and is_table_row(line)
            and index + 1 < len(lines)
            and is_separator(lines[index + 1])
            and not is_separator(line)
        ):
            end = index + 2
            while end < len(lines) and is_table_row(lines[end]):
                end += 1
            output.extend(format_table(lines[index:end]))
            index = end
            continue
        output.append(line)
        index += 1
    return "\n".join(output)


def markdown_files(targets: list[str]) -> list[Path]:
    files: list[Path] = []
    for target in targets:
        path = Path(target)
        if path.is_dir():
            files.extend(sorted(path.rglob("*.md")))
        elif path.suffix == ".md" and path.exists():
            files.append(path)
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Align the columns of Markdown tables.")
    parser.add_argument("paths", nargs="*", help="Markdown files or directories (default: README.md AGENTS.md doc)")
    parser.add_argument("--check", action="store_true", help="do not write; exit 1 when a table is misaligned")
    args = parser.parse_args(argv)
    misaligned = []
    for path in markdown_files(args.paths or list(DEFAULT_TARGETS)):
        original = path.read_text(encoding="utf-8")
        aligned = align_text(original)
        if aligned == original:
            continue
        misaligned.append(path)
        if not args.check:
            path.write_text(aligned, encoding="utf-8")
    verb = "misaligned tables in" if args.check else "aligned tables in"
    for path in misaligned:
        print(f"{verb} {path}")
    return 1 if args.check and misaligned else 0


if __name__ == "__main__":
    sys.exit(main())
