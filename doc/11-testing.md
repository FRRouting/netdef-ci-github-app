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
| Unit         | `tests/unit/` (234)       | HMAC/Basic security, config, models and state machine, formatter, GitHub/Bamboo/Slack clients (with `respx`), job queue (reservation, back-off, lock expiry, debounce, timeout, concurrency with 4 workers), services (BuildPlan, UpdateStatus, Summary, Finished, executions, rerun, retry), tasks (timeout, WatchDog, PrBambooSync, SingleSync), Slack commands, CLI, log redaction, metrics |
| Integration  | `tests/integration/` (45) | full HTTP contract via `TestClient` (equivalent to `spec/app/github_app_spec.rb`), end-to-end flows webhook → queue → fake Bamboo/GitHub → callbacks → consolidation, and Alembic migrations on PostgreSQL                                                                                                                                                                                     |
| Real process | `scripts/smoke_test.py`   | multi-worker uvicorn + worker + migrations + aggregated metrics                                                                                                                                                                                                                                                                                                                                |

Required cases covered: authentication (valid/missing/wrong HMAC, different bytes, Slack/metrics Basic), invalid signature, unsupported events (401 / 405 / `Just a comment`), integration failures (Bamboo down → 418/503, 429, GitHub 404/401/5xx/rate limit, Slack down), **duplicate deliveries** (`X-GitHub-Delivery` with TTL; repeated callbacks → 304; repeated `synchronize`), concurrency (workers and per-PR lock), bounded retries and no retry on non-idempotent operations, secret redaction, migrations on an empty/existing database.

## Results (run of 2026-10-26)

Environment: Python **3.15.2** (built from the python.org tarball), PostgreSQL 17 in a container, dependencies from `requirements-dev.txt`.

| Check              | Command                                                           | Result                                                                                                                                                            |
|--------------------|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Lint               | `ruff check src tests migrations scripts`                         | `All checks passed!`                                                                                                                                              |
| Formatting         | `ruff format --check …`                                           | `79 files already formatted`                                                                                                                                      |
| Types              | `mypy src`                                                        | `Success: no issues found in 43 source files`                                                                                                                     |
| Tests (PostgreSQL) | `pytest tests --cov`                                              | **279 passed**, 0 warnings; coverage **94.37 %** (required minimum 90 %)                                                                                          |
| Tests (SQLite)     | `pytest tests` without `TEST_DATABASE_URL`                        | 271 passed, 8 skipped (PostgreSQL only)                                                                                                                           |
| Dependencies       | `pip check`                                                       | `No broken requirements found.`                                                                                                                                   |
| Smoke test         | `python scripts/smoke_test.py`                                    | 12 `ok` checks (migrations, `/ping`, `/healthz`, `/readyz`, signed webhook/no signature/wrong signature, `/metrics` aggregating 2 workers, clean worker shutdown) |
| Ansible            | `ansible-playbook --syntax-check` ×3, `ansible-lint` (production) | OK / 0 failures; convergence in a systemd container (see `10`)                                                                                                    |

Coverage per module (branches included): the business modules (`services/*`, `web/*`, `jobs/*`, `models`, `security`) sit between 91 % and 100 %; the lowest are `clients/slack.py` (85 %), `container.py` (79 %, real client wiring) and `commits.py` (84 %).

Not executed/validated: see `12-limitations-and-pending.md`.

## GitHub Actions pipeline

`.github/workflows/python.yml` runs on pushes to `master`, `develop` and `feature/**` and on pull requests to `master`/`develop`; `v*` tags run it through `.github/workflows/release.yml`:

| Job         | What it does                                                                                                                                                                                                                                                                          |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `lint`      | `ruff check`, `ruff format --check`, `mypy src` (Python 3.15.2), Markdown tables aligned (`scripts/align_md_tables.py --check`)                                                                                                                                                       |
| `tests`     | `pytest` (unit + integration) against a PostgreSQL 17 service, coverage must stay >= 90 %, `pip check`                                                                                                                                                                                |
| `smoke`     | `scripts/smoke_test.py`: real uvicorn + worker processes (runs after `lint` and `tests`)                                                                                                                                                                                              |
| `ansible`   | `ansible-lint` (production profile) and `--syntax-check` of the deploy playbook for dev and prod                                                                                                                                                                                      |
| `ci-passed` | aggregates the jobs above; **mark it as a required status check** in the branch protection rules so a branch version can only be released when everything is green                                                                                                                    |
| `release`   | `release.yml`, only for `v*` tags and only after the whole `python.yml` gate passed: builds `netdef-ci-<tag>.tar.gz` with `git archive` and publishes a GitHub release. It lives in its own workflow so pull requests and branch pushes do not show a skipped "Release package" check |

Deploy a released version with `-e netdef_ci_version=<tag>` (see `10-ansible-deploy.md`).
