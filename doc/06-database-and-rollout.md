# 06 — Database, rollout and rollback

## Schema

The service uses a single PostgreSQL database. The schema is defined by the SQLAlchemy models in `models.py` and versioned with Alembic (`migrations/versions/`).

| Group             | Tables                                                                                                                                                                                  | Created by                    |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| Domain tables (13) | `organizations`, `github_users`, `pull_requests`, `pull_request_subscriptions`, `plans`, `check_suites`, `stages`, `ci_jobs`, `stage_configurations`, `audit_statuses`, `audit_retries`, `audit_retries_ci_jobs`, `topotest_failures` | `0001_initial_schema`         |
| Background queue  | `jobs` (JSON payloads, queue, priority, `run_at`, attempts, lock and failure columns)                                                                                                   | `0002_python_tables`          |
| Deduplication     | `webhook_deliveries` (stays empty while `WEBHOOK_DEDUPE_TTL_SECONDS=0`)                                                                                                                 | `0002_python_tables`          |
| Versioning        | `alembic_version`                                                                                                                                                                       | Alembic                       |

Status values are stored as integers (`queued` 0 … `skipped` -3) and audit rows use `auditable_type` (`CiJob`/`Stage`).

### Migrations

| Revision               | What it does                                                                                                                                                       | Downgrade                                                            |
|------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| `0001_initial_schema`  | Creates the domain tables **only if they are absent**; on a database that already has them it changes nothing                                                      | Not supported by design (raises an error: the tables hold the data)  |
| `0002_python_tables`   | Adds `jobs` and `webhook_deliveries`                                                                                                                               | Drops `webhook_deliveries` and `jobs`                                |

Commands:

| Command                                | Purpose                                                                                                                              |
|----------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `python -m netdef_ci migrate`          | Applies all pending migrations (`alembic upgrade head`). Idempotent; the Ansible deploy runs it on every release.                    |
| `python -m netdef_ci stamp-baseline`   | Marks a database whose domain tables already exist as revision `0001_initial_schema` (`--revision` selects another one) without running it. Optional, since the baseline is a no-op on existing tables. |
| `python -m netdef_ci check-config`     | Validates configuration, GitHub App keys and database connectivity.                                                                  |
| `python -m netdef_ci purge-jobs`       | Deletes every pending background job (use with care).                                                                                |

Schema changes are made only through new Alembic revisions. `tests/integration/test_migrations.py` checks that the models and the migrations describe the same schema.

## Data and backups

- Back up the database with `pg_dump -Fc <database> > backup-<date>.dump` before every release that includes a migration, and on a regular schedule.
- The `jobs` table only holds transient work. After a restore, pending jobs are re-created by the watch dog and the execution timeout; `purge-jobs` clears the queue if stale jobs are not wanted.
- Timestamps are stored as naive UTC in `timestamp without time zone` columns.
- `webhook_deliveries` rows expire after `WEBHOOK_DEDUPE_TTL_SECONDS` and can be removed at any time.

## First rollout

> The procedure was validated in a local environment (see `10-ansible-deploy.md`); adapt the inventory names to your environment.

1. **Preparation**
   - Create the PostgreSQL database and user, and back up the database if it already contains data.
   - Fill in the production vault: webhook secret (`WEBHOOK_SECRET`), GitHub App `.pem` keys, Bamboo and Slack credentials, `metrics_auth`, database URL.
   - Review `netdef_ci_timers` (watch dog every 15 minutes, `pr-bamboo-sync` hourly) and `CI_URL` in the inventory.
2. **Rehearsal in development:** `ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass`; open a test PR and follow the check runs, Bamboo callbacks and Slack messages. Run `python -m netdef_ci check-config`.
3. **Production deploy:** `ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=<tag>`. The playbook installs the release, applies `migrate`, installs and starts the services and timers, and runs the health check.
4. **Verification:** redeliver a `ping` from the GitHub App (Recent Deliveries), check `GET /readyz` and `GET /metrics`, then open a real PR.
5. **Post-deploy:** watch `journalctl -u 'netdef-ci-*' -f`, the `delayed_jobs_*` metrics (`delayed_jobs_failed`, `delayed_jobs_locked_too_long`), `app_exceptions_total` and `bamboo_api_requests_total`.

## Release rollback

| Situation                                              | Action                                                                                                                                                                                                       |
|--------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Defect in the deployed release, database intact        | `ansible-playbook -i inventories/prod/hosts.yml playbooks/rollback.yml --ask-vault-pass` returns to the previous release (or `-e netdef_ci_rollback_to=<id>` for a specific one). No reverse migration is needed: tables added by newer migrations are ignored by older releases. |
| Corrupted data                                         | Restore the `pg_dump` taken before the release (everything written afterwards is lost).                                                                                                                      |

## Database downgrade notes

- `alembic downgrade 0001_initial_schema` removes `jobs` and `webhook_deliveries` (pending jobs are lost). Do it only if the older release does not need them.
- `0001_initial_schema` cannot be downgraded.
- Executions in progress during a rollback or restart may keep `in_progress` check runs until the watch dog or the execution timeout reconciles them (at most about 15 minutes with the default timer).
