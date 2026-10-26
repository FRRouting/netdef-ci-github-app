# 03 — Technical decisions

## Python version

| Item             | Value                                                                                                                                                                        |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Chosen version   | **Python 3.15.2**                                                                                                                                                            |
| Source           | python.org (releases API: `Python 3.15.2`, `is_latest: true`, `pre_release: false`, published on 2026-10-25)                                                                 |
| Queried on       | 2026-10-26 (migration date). Other stable lines: 3.14.10, 3.13.18; `3.16.0a1` is an alpha and was ignored                                                                    |
| Tarball          | `https://www.python.org/ftp/python/3.15.2/Python-3.15.2.tar.xz` — 27 960 396 bytes (matches the API)                                                                         |
| SHA-256          | `8b5536d280142ecf6cdfe15d12a21ba1c65e300bbf7b28a8d0cdb849575797de` (computed locally over the TLS download; the sigstore signature was not verified automatically)           |
| Compatibility    | All dependencies have `cp315` *wheels* (checked with `pip install --only-binary=:all:`); there was no need to step back to an older version                                  |

Tests, lint and `mypy` were run with 3.15.2 compiled from that tarball
(`scripts/Containerfile.dev`). On the servers, Ansible compiles the same version into `/opt/python/3.15.2`.

## Chosen stack (and what each piece replaces)

| Need (in Ruby)                         | Choice in Python                                                                  | Rationale                                                                                                                                                                                                                                 |
|----------------------------------------|-----------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Sinatra + Puma + Rack                  | **FastAPI** + **uvicorn** (multiprocess)                                          | Simple routing, raw body access, typing. Automatic docs disabled (they did not exist in Ruby).                                                                                                                                            |
| ActiveRecord (otr-activerecord) + `pg` | **SQLAlchemy 2** + **psycopg 3**                                                  | Mature ORM; maps the existing schema without changes.                                                                                                                                                                                     |
| ActiveRecord migrations                | **Alembic**                                                                       | Baseline that reproduces the Ruby schema and adopts existing databases.                                                                                                                                                                   |
| Delayed Job                            | **Own PostgreSQL queue** (`jobs/queue.py`)                                        | Avoids Redis/a new broker, with `run_at`, queues, 5 attempts, DJ back-off, 5 min lock and *debounce*. ~150 lines; avoids a dependency (Celery/RQ would require Redis; Procrastinate would bring its own schema and async model).          |
| Octokit + jwt                          | **httpx** + **PyJWT[crypto]**                                                     | Direct REST calls (few endpoints), token caching/renewal and bounded retries under our control.                                                                                                                                           |
| Net::HTTP + netrc                      | **httpx** + stdlib `netrc`                                                        | Keeps `~/.netrc` as the credentials fallback.                                                                                                                                                                                             |
| prometheus-client (DirectFileStore)    | **prometheus-client** (multiprocess mode)                                         | Same metric names; web and workers share counters.                                                                                                                                                                                        |
| `config.yml` / `database.yml`          | **pydantic-settings** (environment variables / `.env`) + TOML for the GitHub Apps | 12-factor; `tomllib` is in the stdlib (PyYAML has no *wheel* for 3.15).                                                                                                                                                                   |
| RSpec + FactoryBot + WebMock           | **pytest** + factories in `tests/factories.py` + **respx**                        | Same philosophy: no real network calls in tests.                                                                                                                                                                                          |
| Rubocop                                | **ruff** (lint + format) and **mypy**                                             | Equivalent quality gate.                                                                                                                                                                                                                  |

Poetry/Pipenv were not adopted: `requirements.txt` (runtime) and `requirements-dev.txt` (includes the former) with pinned
versions. `pyproject.toml` contains only tool configuration. `httpx2` is dev-only because
`starlette.testclient` requires it (the application uses `httpx`).

## Implementation principles

- **Reference = executed code.** The Ruby documentation was used as support; divergences are in `07-divergences-and-improvements.md`.
- **External contracts preserved:** routes, headers, response codes and bodies, metric names, database schema, Slack messages, variables/URLs sent to Bamboo.
- **No literal translation:** services receive a `Session` and use injectable clients (`container.py`), which enables network-free tests.
- **Explicit errors:** specific exceptions in the clients, `503` when Bamboo is unavailable (instead of finishing suites by mistake), auxiliary failures (reactions, user data, Slack) never bring down the CI flow.
- **Bounded retries** only where idempotency is guaranteed (see `08-persistence-concurrency-failures.md`).
