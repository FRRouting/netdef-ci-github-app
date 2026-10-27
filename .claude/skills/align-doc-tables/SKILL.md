---
name: align-doc-tables
description: Use whenever you create or edit a Markdown table (or any row of one) in README.md, AGENTS.md or doc/*.md, and before finishing any change that touched documentation. Keeps every column of every table aligned by running scripts/align_md_tables.py instead of padding cells by hand.
---

# Keep documentation tables aligned

Every Markdown table in this repository (`README.md`, `AGENTS.md`, `doc/*.md`) has its columns aligned: cells padded
to the widest cell of the column and a separator row without inner spaces (`|------|:----:|`). Never pad cells by
hand; write the content and let the script align it.

## When

- After adding, removing or editing any table row or cell, including a single new row in an existing table.
- Before finishing any task that changed documentation (also run the `document-in-english` check).

## How

```bash
python scripts/align_md_tables.py                 # aligns README.md, AGENTS.md and doc/ in place
python scripts/align_md_tables.py doc/07-design-notes.md   # only the given files/directories
python scripts/align_md_tables.py --check         # report misaligned files, exit 1 (used by `make lint` and CI)
```

`make docs-tables` runs the in-place alignment; `make lint` and the CI `lint` job run `--check`.

## Rules the script follows (keep them when writing tables)

1. A table is a row starting with `|` followed by a separator row (`---`, `:---`, `:---:`, `---:`); rows inside
   fenced code blocks are ignored.
2. Alignment markers are preserved: centred and right-aligned columns are padded accordingly.
3. Rows with fewer cells get empty cells; a literal pipe inside a cell must be written as `\|`.
4. Width is the display width (wide characters count twice), so tables also line up with non-ASCII text.

## Quick check before finishing

```bash
python scripts/align_md_tables.py --check
```

The command must print nothing and exit 0. Review the diff afterwards: only whitespace and dashes of the touched
tables should change.
