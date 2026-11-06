# AGENTS.md — guide for AI agents and contributors

Project: **netdef-ci-github-app**, a standalone Python service (a GitHub App that
connects Pull Requests to Bamboo CI). Design notes and deliberate behaviours are recorded in
`doc/07-design-notes.md`.

Read this whole file before changing code. The "Code conventions" section describes how the existing code is written;
new code must look like the code around it. When in doubt, copy the closest existing example named below.

## Read `doc/` before implementing

Before implementing anything, an AI agent (or contributor) must read the pages of `doc/` that cover the area being
changed, so the change follows the decisions already taken instead of inventing a new pattern. At minimum read
`doc/01-overview.md` (architecture) and `doc/07-design-notes.md` (deliberate behaviours), plus the pages below that
match the task. If what you are about to do contradicts something in `doc/`, stop and ask instead of silently
diverging.

| Task touches                                         | Read first                                           |
|------------------------------------------------------|------------------------------------------------------|
| Any change                                           | `doc/01-overview.md`, `doc/07-design-notes.md`       |
| Features, flows or their tests                       | `doc/02-feature-test-matrix.md`, `doc/11-testing.md` |
| Python version, dependencies, libraries, tooling     | `doc/03-technical-decisions.md`                      |
| Settings, environment variables, GitHub App, secrets | `doc/04-configuration-and-environment.md`            |
| HTTP routes, webhooks, request/response formats      | `doc/05-api-endpoints.md`                            |
| Models, migrations, rollout/rollback                 | `doc/06-database-and-rollout.md`                     |
| Jobs, locks, retries, idempotency, failure handling  | `doc/08-persistence-concurrency-failures.md`         |
| Logs, metrics, health checks, systemd units          | `doc/09-operations.md`                               |
| Ansible roles, inventories, deploy                   | `doc/10-ansible-deploy.md`                           |
| A new Bamboo plan or repository                      | `doc/12-adding-a-plan.md`                            |
| Creating, installing or activating the GitHub App    | `doc/13-github-app-setup.md`                         |

## Document every change

A change is not finished until the documentation describes it. In the same change (same commit/PR) as the code:

- Update the `doc/` page(s) from the table above whose content the change affects: new or changed behaviour, setting,
  endpoint, job, metric, table/column, deploy step or operational procedure. Remove or correct text that became wrong.
- Record deliberate behaviour decisions (and why they were taken) in `doc/07-design-notes.md`.
- Add new features and their tests to `doc/02-feature-test-matrix.md`.
- If a new topic does not fit any existing page, add a new numbered page in `doc/` and link it from `README.md`.
- Keep `AGENTS.md` itself current when a convention or project rule changes.

## Language rule

**Everything written in this repository is in English**: documentation (`README.md`, `doc/`), code comments,
docstrings, log/error/user-facing messages, commit messages, Ansible task names and comments, test names.

## Project rules

- Python **3.13** (3.13.18 pinned in CI, containers and Ansible; see `doc/03-technical-decisions.md`).
  Dependencies **only** in `requirements.txt` (runtime) and `requirements-dev.txt`, always pinned. Do not introduce
  Poetry/Pipenv. Avoid new dependencies.
- Layout `src/netdef_ci/`: `web/` only authenticates and delegates; business rules in `services/`; external calls in
  `clients/`; queue in `jobs/`; models in `models.py`. Routes never make slow external calls: they enqueue a job.
- Every `.py` file starts with the SPDX/NetDEF header (copy from an existing one).
- Typing is mandatory (`mypy src` clean), `ruff check` and `ruff format` clean, lines up to 120 columns.
- Never log tokens, keys or secrets (`logs.py` redacts known patterns, but do not rely on it alone).
- Operations with non-idempotent external side effects (starting a Bamboo plan) run with `max_attempts=1`.
- Tests: `pytest` in `tests/unit` and `tests/integration`; external HTTP only through `respx`/doubles in `tests/fakes.py`.
  No test touches real resources. Test database: PostgreSQL via `TEST_DATABASE_URL` (or SQLite).
- Deliberate behaviour decisions must be recorded in `doc/07-design-notes.md`.
- Markdown tables stay aligned: after touching one, run `make docs-tables` (skill `.claude/skills/align-doc-tables/SKILL.md`).
- Schema: changes only through Alembic migrations in `migrations/versions/` (revision `0001_initial_schema` is the baseline).

## Code conventions

### Module layout and responsibilities

| Package / module  | Owns                                                                                                 | Never does                                                 |
|-------------------|------------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| `web/app.py`      | FastAPI routes, HMAC/Basic auth (`security.py`), JSON parsing, metrics of the request                | business rules, ORM queries, calls to GitHub/Bamboo        |
| `web/webhooks.py` | Delivery de-duplication and dispatch of a GitHub event / Bamboo callback to a service                | the work itself                                            |
| `services/`       | Business rules; one module per flow (`build_plan.py`, `retry.py`, `finished.py`, ...)                | building `httpx` clients, reading env vars directly        |
| `clients/`        | HTTP to GitHub, Bamboo and Slack (`httpx`), auth, retries, response parsing                          | ORM writes or business decisions                           |
| `jobs/`           | Queue (`queue.py`), handler registry, handlers (`handlers.py`), per-PR locks (`locks.py`)            | business rules (handlers only open a session and delegate) |
| `models.py`       | SQLAlchemy models and small model-level helpers (status transitions, check run updates)              | HTTP calls other than through the `github` passed in       |
| `container.py`    | Process-wide client instances (`container.bamboo()`, `container.slack()`, `container.github(suite)`) | —                                                          |
| `config.py`       | Every setting (`Settings`, `get_settings()`)                                                         | —                                                          |
| `cli/main.py`     | `python -m netdef_ci <command>` (argparse subcommands: worker, watch-dog, migrate, ...)              | business rules (it calls `services/`)                      |

### File skeleton

Every module follows the same shape (see `src/netdef_ci/services/plan_run.py`):

1. SPDX/NetDEF header with the path relative to `src/netdef_ci/` (e.g. `#  services/plan_run.py`).
2. A module docstring that says what the module does in one or two sentences. Modules ported from the original Ruby
   application name the origin: `(port of BambooCi::PlanRun)`.
3. `from __future__ import annotations`.
4. Imports sorted by ruff (`I`): stdlib, third party, `netdef_ci.*`. Always absolute imports (`from netdef_ci.x import y`),
   never relative ones. Import local modules with an alias when the name is ambiguous
   (`from netdef_ci.jobs import queue as jobs_queue`).
5. Module constants in `UPPER_CASE`, with a trailing comment when the value is not obvious.

### Typing

- Annotate every function, including `-> None`. Use builtin generics and `X | None` (`list[str]`, `dict[str, Any]`),
  `collections.abc` for `Callable`, `Iterator`, `Sequence`.
- Common aliases: `Response = tuple[int, str]` in services and `web/webhooks.py`; `Json`/`JsonDict = dict[str, Any]` in
  clients. Reuse them instead of inventing new names.
- Narrow optionals with `assert x is not None` (the codebase does this for relationships such as
  `check_suite.pull_request`). Use `# type: ignore[code]` only with the specific error code.
- Model columns use `Mapped[...]` + `mapped_column(...)` (SQLAlchemy 2.0 style).

### Services

- A flow is either a class with the session and payload in `__init__` and a public verb method returning a `Response`
  (`BuildPlan(session, payload).create()`, `RetryComment(session, payload).schedule()`,
  `UpdateStatus(session, payload).update()`), or a plain function taking `session` first
  (`tasks.ci_job_status(session, bamboo_ci_ref, ci_job_id)`).
- Job-driven flows expose a `@classmethod run(cls, session, ...)` that loads rows by id and does the work inside
  `pull_request_lock(pull_request_id)` when it cancels/starts executions (see `services/executions.py`).
- Results to the caller are `(http_status, message)` tuples — `200/202` for accepted work, `4xx` for invalid input
  or nothing to do, `5xx` only when the delivery should be retried. Exceptions are for programming errors and
  unavailable dependencies (`BambooUnavailable`), not for ordinary "ignore this event" outcomes.
- Reach external systems only through `container.bamboo()`, `container.slack()` and `container.github(check_suite)`;
  never instantiate a client in a service. This is what lets tests swap them with `container.override(...)`.
- Read nested payload values with `dig(payload, "pull_request", "head", "sha")` from `services/executions.py`; do not
  write another copy of it. Shared query helpers live in `services/common.py` (e.g. `find_pull_request`).
- Long waits take an injectable `sleep: Callable[[float], None] = time.sleep` and are bounded by a setting
  (see `wait_until_stopped`), so tests never sleep.

### Database and sessions

- Queries use SQLAlchemy 2.0 `select()` with `session.scalars(...)`/`session.execute(...)`/`session.get(...)`. Do not
  use the legacy `session.query()`. Add `.order_by(...)` whenever the result depends on row order (`.limit(1)`).
- Outside a request, open sessions with `with session_scope() as session:` (`db.py`). It always closes and rolls back
  on errors, but **never commits implicitly**: call `session.commit()` explicitly.
- Model helpers and `jobs_queue.enqueue(...)` accept `commit=False` so several changes and the jobs they schedule land
  in one transaction; prefer that when a flow writes more than one row.
- Timestamps are naive UTC: use `db.utcnow()`, never `datetime.now()`/`datetime.utcnow()` for values stored in the
  database.
- Status columns use `enums.Status` (stable integer values) and the groups `RUNNING_STATUSES` / `FAILED_STATUSES`.
  Never store raw integers or strings for a status.
- Code must run on PostgreSQL (production) and SQLite (fast tests). PostgreSQL-only features (advisory locks,
  `NOTIFY`, `CONCURRENTLY`) are guarded by `dialect.name == "postgresql"`, as in `jobs/locks.py` and `jobs/queue.py`.
- A schema change needs a new Alembic revision (`000N_<short_name>.py`, `down_revision` = previous one) **and** the
  matching change in `models.py`. Index names follow `index_<table>_on_<column>`.

### Background jobs

- A job is a function in `jobs/handlers.py` decorated with `@job_handler("<name>")`. It opens a `session_scope()`
  and delegates to a service in one or two lines; no logic in the handler.
- Job arguments are JSON-serializable values (ids, strings, the webhook payload dict), never ORM objects. The service
  reloads rows by id.
- Enqueue with `jobs_queue.enqueue(session, "<name>", [args...], queue=..., delay_seconds=..., max_attempts=...)`.
  Flows that start Bamboo plans use `queue=jobs_queue.execution_queue(name, github_pr_id)` and `max_attempts=1`
  with a comment saying why. Debounced work uses `jobs_queue.replace_pending(...)` with a `dedupe_key`.
- Raise an exception from a handler only when retrying the job is safe and useful.

### External clients

- Clients take `Settings` in `__init__` plus injectable `transport: httpx.BaseTransport | None` and `sleep` for tests
  (see `BambooClient`). They own one `httpx.Client` with `timeout=settings.http_timeout_seconds`.
- Retries go through `clients/http.request_with_retries`: transport errors and 5xx are retried only for idempotent
  methods; POST is never repeated except on rate limits.
- Bamboo/Slack helpers return `None` (or a falsy value) and log on failure instead of raising, so a CI flow is not
  interrupted by a notification. GitHub errors raise `GithubError`/`GithubNotFound`.
- Summarize HTTP responses in logs with `response_summary(response)`; never log headers or request bodies with
  credentials.

### Configuration

- Every setting is a field of `Settings` in `config.py`: `snake_case` name, `UPPER_CASE` env alias, a safe default and
  bounds (`ge=`, `gt=`, `le=`), e.g. `Field(60, alias="RUNNING_PLAN_WAIT_SECONDS", ge=0)`. Durations carry the unit in
  the name (`_seconds`, `_minutes`, `_hours`). Secrets are `SecretStr` and are read with `.get_secret_value()` only
  where they are used.
- Put a comment above a non-obvious setting explaining what it controls, and document new variables in
  `doc/04-configuration-and-environment.md` (and in the Ansible role defaults when deployed values change).
- Read settings with `get_settings()` at call time, not at import time.

### Logging and metrics

- Use `Log("<component>", pr_id)` from `logs.py` (`self.log = Log(...)` in classes, module-level `log = Log(...)`
  otherwise). Passing the pull request number mirrors the line into that PR's log file.
- Use `%s` placeholders with arguments (`log.info("Starting Plan: %s", plan.name)`), never f-strings in log calls.
- Messages say what happened and identify the objects involved (plan, check suite id, Bamboo ref, HTTP status).
  `error` for failures that need attention, `warning` for ignored/odd input, `info` for flow milestones, `debug` for
  noise. `print` is only allowed in `cli/` (ruff `T20`).
- Prometheus metrics are declared once in `metrics.py` (`UPPER_CASE` names) and updated from services/clients with
  low-cardinality labels. Metrics decisions go to `doc/07-design-notes.md` section 3.

### Comments and docstrings

- Docstrings are short and explain *why* or the contract (return value, units, side effects), not a line-by-line
  narration. Mention the setting that bounds a behaviour (e.g. "bounded by RUNNING_PLAN_WAIT_SECONDS").
- Inline comments are reserved for non-obvious decisions (`# starts a Bamboo plan: never repeated automatically`).
- Sections of long classes may be separated with `# ----- <name>` rulers, as in `clients/bamboo.py` and `web/app.py`.
- Private helpers start with `_`. Public names are what other modules or tests import.

### Tests

- Every behaviour change comes with tests; coverage must stay at or above 90 % (`fail_under` in `pyproject.toml`).
- Unit tests live in `tests/unit/test_<module>.py`; HTTP-level tests in `tests/integration/` use the signed `Api`
  client from `tests/integration/conftest.py`.
- Test names describe the behaviour as a sentence: `test_unplanned_repository_returns_422`,
  `test_valid_event_creates_pr_user_and_schedules_one_job_per_plan`.
- Fixtures from `tests/conftest.py`: `session` (clean database per test), `clients` (installs `FakeGithub`,
  `FakeBamboo`, `FakeSlack` through `container.override`), `github`/`bamboo`/`slack` (the fakes, to assert calls),
  `settings`. Use `monkeypatch.setattr(settings, ...)` to change a setting inside a test.
- Build rows with `tests/factories.py` (`from tests import factories as f`; `f.World(session)` gives a PR, plan,
  check suite, two stages and two jobs) and webhook bodies with `tests/payloads.py`. Do not hand-build payloads that a
  helper already produces; extend the helper instead.
- Client tests mock HTTP with `respx` (`respx.mock(assert_all_called=False)`) and inject `sleep=list.append` to assert
  back-off without waiting.
- Assert the observable result: the returned `(status, body)`, rows in the database, enqueued `Job` rows
  (handler, queue, `max_attempts`) and calls recorded by the fakes. `pytest.mark.parametrize` covers variants of the
  same rule.
- PostgreSQL-only behaviour is skipped on SQLite with `IS_PG` from `tests/conftest.py`.

### Checklist before finishing a change

1. `make check` passes (ruff lint + format, Markdown tables, mypy, tests with coverage).
2. New settings documented; new behaviours recorded in `doc/07-design-notes.md`; schema changes have a migration.
3. Every affected `doc/` page updated to describe what was changed (see "Document every change").
4. No secrets in logs, tests or docs; all new text in English.

## Commands

```bash
make install-dev && make check          # lint + mypy + tests with coverage
scripts/test-with-podman.sh             # same gate with Python 3.13.18 and PostgreSQL in containers
make smoke                              # starts real uvicorn + worker against a test PostgreSQL
make docs-tables                        # aligns every Markdown table (lint runs it with --check)
```
