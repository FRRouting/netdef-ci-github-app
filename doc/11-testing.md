# 11 — Tests and quality checks

## How to run

```bash
# local (Python 3.15.x)
python3.15 -m venv .venv && . .venv/bin/activate
pip install --only-binary=:all: -r requirements-dev.txt
export TEST_DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/githubruns-test   # optional; without it SQLite is used
make check                  # ruff + ruff format --check + mypy + pytest with coverage (minimum 90 %)
make smoke                  # real processes (uvicorn 2 workers + worker) against a test PostgreSQL

# reproducible, everything in containers (Python 3.15.2 built from the tarball + PostgreSQL 17)
scripts/test-with-podman.sh
```

- Database: `TEST_DATABASE_URL` (PostgreSQL → applies the Alembic migrations; this is the mode used as evidence) or, if absent, SQLite in a temporary file (the 8 tests that require PostgreSQL — migrations, `SKIP LOCKED`, advisory lock — are skipped).
- No test uses the network or real resources: external HTTP is intercepted with `respx` or replaced by test doubles (`tests/fakes.py`: `FakeGithub`, `FakeBamboo`, `FakeSlack`); data is synthetic (`tests/payloads.py`, `tests/factories.py`); RSA keys are generated at test time.

## Organization

| Layer        | Files                     | Content                                                                                                                                                                                                                                                                                                                                                                                        |
|--------------|---------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Unit         | `tests/unit/` (208)       | HMAC/Basic security, config, models and state machine, formatter, GitHub/Bamboo/Slack clients (with `respx`), job queue (reservation, back-off, lock expiry, debounce, timeout, concurrency with 4 workers), services (BuildPlan, UpdateStatus, Summary, Finished, executions, rerun, retry), tasks (timeout, WatchDog, PrBambooSync, SingleSync), Slack commands, CLI, log redaction, metrics |
| Integration  | `tests/integration/` (44) | full HTTP contract via `TestClient` (equivalent to `spec/app/github_app_spec.rb`), end-to-end flows webhook → queue → fake Bamboo/GitHub → callbacks → consolidation, and Alembic migrations on PostgreSQL                                                                                                                                                                                     |
| Real process | `scripts/smoke_test.py`   | multi-worker uvicorn + worker + migrations + aggregated metrics                                                                                                                                                                                                                                                                                                                                |

Required cases covered: authentication (valid/missing/wrong HMAC, different bytes, Slack/metrics Basic), invalid signature, unsupported events (401 / 405 / `Just a comment`), integration failures (Bamboo down → 418/503, 429, GitHub 404/401/5xx/rate limit, Slack down), **duplicate deliveries** (`X-GitHub-Delivery` with TTL; repeated callbacks → 304; repeated `synchronize`), concurrency (workers and per-PR lock), bounded retries and no retry on non-idempotent operations, secret redaction, migrations on an empty/existing database.

## Results (run of 2026-10-26)

Environment: Python **3.15.2** (built from the python.org tarball), PostgreSQL 17 in a container, dependencies from `requirements-dev.txt`.

| Check              | Command                                                           | Result                                                                                                                                                            |
|--------------------|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Lint               | `ruff check src tests migrations scripts`                         | `All checks passed!`                                                                                                                                              |
| Formatting         | `ruff format --check …`                                           | `79 files already formatted`                                                                                                                                      |
| Types              | `mypy src`                                                        | `Success: no issues found in 43 source files`                                                                                                                     |
| Tests (PostgreSQL) | `pytest tests --cov`                                              | **252 passed**, 0 warnings; coverage **94.31 %** (required minimum 90 %)                                                                                          |
| Tests (SQLite)     | `pytest tests` without `TEST_DATABASE_URL`                        | 244 passed, 8 skipped (PostgreSQL only)                                                                                                                           |
| Dependencies       | `pip check`                                                       | `No broken requirements found.`                                                                                                                                   |
| Smoke test         | `python scripts/smoke_test.py`                                    | 12 `ok` checks (migrations, `/ping`, `/healthz`, `/readyz`, signed webhook/no signature/wrong signature, `/metrics` aggregating 2 workers, clean worker shutdown) |
| Ansible            | `ansible-playbook --syntax-check` ×3, `ansible-lint` (production) | OK / 0 failures; convergence in a systemd container (see `10`)                                                                                                    |

Coverage per module (branches included): the business modules (`services/*`, `web/*`, `jobs/*`, `models`, `security`) sit between 91 % and 100 %; the lowest are `clients/slack.py` (85 %), `container.py` (79 %, real client wiring) and `commits.py` (84 %).

Not executed/validated: see `12-limitations-and-pending.md`.
