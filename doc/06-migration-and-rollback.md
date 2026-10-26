# 06 — Migration strategy, go-live and rollback

## Data compatibility

The Python version uses the **same PostgreSQL database and the same schema** as Ruby (`db/schema.rb` 2025_08_22_071834): same tables,
columns, indexes, status enum integers (`queued 0 … skipped -3`) and `auditable_type` (`CiJob`/`Stage`). No data is converted.

| Item                     | Ruby                                   | Python                                                                         |
|--------------------------|----------------------------------------|--------------------------------------------------------------------------------|
| Domain tables (13)       | ActiveRecord                           | SQLAlchemy over the same tables                                                |
| Queue                    | `delayed_jobs` (Ruby YAML handlers)    | **new** `jobs` table (JSON) — `delayed_jobs` is neither read nor changed       |
| Webhook deduplication    | —                                      | **new** `webhook_deliveries` table (empty if `WEBHOOK_DEDUPE_TTL_SECONDS=0`)   |
| Schema versioning        | `schema_migrations`                    | `alembic_version` (the two tables coexist)                                     |

The Alembic migrations: `0001_ruby_baseline` (creates the Ruby schema **only if the tables do not exist**; on an existing database it changes nothing)
and `0002_python_tables` (`jobs`, `webhook_deliveries`). They are additive: Ruby keeps working on the same database, which makes rollback viable.

Prerequisite: the database must have all Ruby migrations applied (`rake db:migrate`, version `20250822071834`).
If the database is older, migrate with Ruby first.

## Go-live procedure

> None of the steps below was executed on real servers; the procedure was validated in a local environment (see `10-ansible-deploy.md`).

1. **Preparation (no impact)**
   - Database backup: `pg_dump -Fc githubruns-prod > backup-<date>.dump`.
   - Fill in the production vault with the **same** secrets as Ruby (`auth_signature.password` → `webhook_secret`, `.pem` keys, `~/.netrc` passwords, `metrics_auth`, `slack_bot_url`). Keeping the same `WEBHOOK_SECRET` avoids touching GitHub and Bamboo.
   - Check `netdef_ci_timers` against the current crontab (`bin/watch_dog_prod.sh`, `bin/pr_bamboo_sync.sh`) and `CI_URL`.
2. **Rehearsal in development:** `ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass`; open a test PR and follow check runs, callbacks and Slack. Run `python -m netdef_ci check-config`.
3. **Cutover window** (ideally with no executions in progress):
   1. Stop the intake of new events: `systemctl stop github_server` (Ruby). Executions already started in Bamboo continue and their callbacks will fail while no server is up — so the window must be short; the WatchDog reconciles afterwards.
   2. **Drain the Ruby queue:** check `SELECT count(*) FROM delayed_jobs;` (it should be 0 or only future `timeout_execution`/`ci_job_status`). Pending Ruby jobs are **not** processed by Python; if any remain, run them with Ruby before shutting it down or consciously discard them (the Python WatchDog/`TimeoutExecution` recreate the consolidation).
   3. Disable the Ruby cron (`watch_dog`, `pr_bamboo_sync`) so there are not two reconcilers.
   4. `ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=<tag>` — applies `migrate`, installs services, starts them and runs the health check.
   5. If the database already had the Ruby schema, `migrate` runs the baseline as a no-op and creates `jobs`/`webhook_deliveries` (optional: `python -m netdef_ci stamp-ruby-schema` beforehand, equivalent).
   6. Ping GitHub (Recent Deliveries → *Redeliver* a `ping`), `GET /readyz`, `GET /metrics`.
4. **Post-cutover:** watch `journalctl -u 'netdef-ci-*' -f`, the `delayed_jobs_*` metrics, `app_exceptions_total`, `bamboo_api_requests_total`; open a real PR. Keep the Ruby service stopped (not removed) for at least one week.

## Rollback

| Situation                                                      | Action                                                                                                                                                                                                                                                                                               |
|----------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Defect in the already deployed Python version, database intact | `ansible-playbook -i inventories/prod/hosts.yml playbooks/rollback.yml --ask-vault-pass` goes back to the previous release (or `-e netdef_ci_rollback_to=<id>`); no reverse migration (the new tables are ignored by older releases)                                                                 |
| Go back to Ruby                                                | `systemctl stop 'netdef-ci-*' netdef-ci.target`; `systemctl start github_server`; re-enable the Ruby cron. The Ruby schema remains intact. Pending jobs in the `jobs` table will not be run by Ruby (executions created by Python and still open will be reconciled by the Ruby WatchDog via Bamboo) |
| Corrupted data                                                 | restore the `pg_dump` from step 1 (loses whatever happened afterwards)                                                                                                                                                                                                                               |

Rollback notes: `alembic downgrade 0001_ruby_baseline` removes `jobs` and `webhook_deliveries` (the baseline is not reversible by design). Executions in progress at the time of the switch may be left with `in_progress` check runs until the WatchDog/timeout acts (≤ 15 min with the default timer).
