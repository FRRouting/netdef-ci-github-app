# AGENTS.md — guide for AI agents and contributors

Project: **netdef-ci-github-app-python**, a standalone Python service (a GitHub App that
connects Pull Requests to Bamboo CI). Design notes and deliberate behaviours are recorded in
`doc/07-design-notes.md`.

## Language rule

**Everything written in this repository is in English**: documentation (`README.md`, `doc/`), code comments,
docstrings, log/error/user-facing messages, commit messages, Ansible task names and comments, test names. Follow the
project skill `.claude/skills/document-in-english/SKILL.md`.

## Project rules

- Python **3.15.2** (see `doc/03-technical-decisions.md`). Dependencies **only** in `requirements.txt` (runtime) and
  `requirements-dev.txt`, always pinned. Do not introduce Poetry/Pipenv. Avoid new dependencies.
- Layout `src/netdef_ci/`: `web/` only authenticates and delegates; business rules in `services/`; external calls in
  `clients/`; queue in `jobs/`; models in `models.py`. Routes never make slow external calls: they enqueue a job.
- Every `.py` file starts with the SPDX/NetDEF header (copy from an existing one).
- Typing is mandatory (`mypy src` clean), `ruff check` and `ruff format` clean, lines up to 120 columns.
- Never log tokens, keys or secrets (`logs.py` redacts known patterns, but do not rely on it alone).
- Operations with non-idempotent external side effects (starting a Bamboo plan) run with `max_attempts=1`.
- Tests: `pytest` in `tests/unit` and `tests/integration`; external HTTP only through `respx`/doubles in `tests/fakes.py`.
  No test touches real resources. Test database: PostgreSQL via `TEST_DATABASE_URL` (or SQLite, skipping the `pg` tests).
- Deliberate behaviour decisions must be recorded in `doc/07-design-notes.md`.
- Markdown tables stay aligned: after touching one, run `make docs-tables` (skill `.claude/skills/align-doc-tables/SKILL.md`).
- Schema: changes only through Alembic migrations in `migrations/versions/` (revision `0001_initial_schema` is the baseline).

## Commands

```bash
make install-dev && make check          # lint + mypy + tests with coverage
scripts/test-with-podman.sh             # same gate with Python 3.15.2 and PostgreSQL in containers
make smoke                              # starts real uvicorn + worker against a test PostgreSQL
make docs-tables                        # aligns every Markdown table (lint runs it with --check)
```
