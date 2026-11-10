# 03 — Technical decisions

## Python version

| Item           | Value                                                                                                                          |
|----------------|--------------------------------------------------------------------------------------------------------------------------------|
| Chosen version | **Python 3.13** — **3.13.18** pinned in CI, `scripts/Containerfile.dev` and the Ansible build                                  |
| Source         | python.org (releases API: `Python 3.13.18`, `pre_release: false`, published on 2026-10-25; latest release of the 3.13 line)    |
| Queried on     | 2026-11-05 (date of the switch from 3.15.2 to 3.13)                                                                            |
| Tarball        | `https://www.python.org/ftp/python/3.13.18/Python-3.13.18.tar.xz` — 23 243 936 bytes (matches the API)                         |
| SHA-256        | `abb0102e6d4ae027509bcb82327d9dd85515b44a3ba8ad538cfc5e9847029f68` (from the API and recomputed locally over the TLS download) |
| Compatibility  | All pinned dependencies have `cp313` *wheels* (checked with `pip download --only-binary=:all: --python-version 3.13`)          |
| Why 3.13       | Debian 13 (trixie), the servers' distribution, ships Python 3.13; see `07-design-notes.md`                                     |

Tests, lint and `mypy` run with 3.13.18 compiled from that tarball (`scripts/Containerfile.dev`). On the servers,
Ansible compiles the same version into `/opt/python/3.13.18`, or uses the distribution's `python3.13` when
`netdef_ci_python_system: true` (`10-ansible-deploy.md`). Until 2026-11-05 the project targeted Python 3.15.2.

## Stack

| Need                  | Choice                                                                            | Rationale                                                                                                                                                                                                                     |
|-----------------------|-----------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Web framework         | **FastAPI** + **uvicorn** (multiprocess)                                          | Simple routing, raw body access, typing. Automatic docs disabled.                                                                                                                                                             |
| ORM / driver          | **SQLAlchemy 2** + **psycopg 3**                                                  | Mature ORM with explicit sessions.                                                                                                                                                                                            |
| Migrations            | **Alembic**                                                                       | Baseline revision that creates the schema and adopts existing databases.                                                                                                                                                      |
| Job queue             | **Own PostgreSQL queue** (`jobs/queue.py`)                                        | Avoids Redis/a new broker, with `run_at`, queues, 5 attempts, back-off, 5 min lock and *debounce*. ~150 lines; avoids a dependency (Celery/RQ would require Redis; Procrastinate would bring its own schema and async model). |
| GitHub client         | **httpx** + **PyJWT[crypto]**                                                     | Direct REST calls (few endpoints), token caching/renewal and bounded retries under our control.                                                                                                                               |
| Bamboo / Slack client | **httpx** + stdlib `netrc`                                                        | Keeps `~/.netrc` as the credentials fallback.                                                                                                                                                                                 |
| Metrics               | **prometheus-client** (multiprocess mode)                                         | Web and workers share counters.                                                                                                                                                                                               |
| Configuration         | **pydantic-settings** (environment variables / `.env`) + TOML for the GitHub Apps | 12-factor; `tomllib` is in the stdlib (no YAML dependency).                                                                                                                                                                   |
| Tests                 | **pytest** + factories in `tests/factories.py` + **respx**                        | No real network calls in tests.                                                                                                                                                                                               |
| Lint / types          | **ruff** (lint + format) and **mypy**                                             | Quality gate.                                                                                                                                                                                                                 |

Poetry/Pipenv were not adopted: `requirements.txt` (runtime) and `requirements-dev.txt` (includes the former) with pinned
versions. `pyproject.toml` contains only tool configuration. `httpx2` is dev-only because
`starlette.testclient` requires it (the application uses `httpx`).

## Implementation principles

- **Reference = executed code.** Design notes and deliberate behaviours are in `07-design-notes.md`.
- **External contracts preserved:** routes, headers, response codes and bodies, metric names, database schema, Slack messages, variables/URLs sent to Bamboo.
- **No literal translation:** flows receive a `Session` and use injectable clients (`container.py`), which enables network-free tests.
- **Explicit errors:** specific exceptions in the clients, `503` when Bamboo is unavailable (instead of finishing suites by mistake), auxiliary failures (reactions, user data, Slack) never bring down the CI flow.
- **Bounded retries** only where idempotency is guaranteed (see `08-persistence-concurrency-failures.md`).
