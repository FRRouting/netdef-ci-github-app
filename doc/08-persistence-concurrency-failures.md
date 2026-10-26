# 08 — Persistence, concurrency, idempotency and failure handling

## Persistence

- PostgreSQL (same schema as Ruby; see `06`). Short SQLAlchemy sessions, with an explicit `commit` on every state change (equivalent to ActiveRecord's *autocommit per `save`*): if a job dies midway, what has already been written stays consistent with what has already been sent to GitHub/Bamboo.
- Dates in "naive" UTC (`timestamp without time zone`), like Rails.
- `AuditStatus` records each transition of `CiJob`/`Stage` (with the agent: `Github` or `WatchDog`); `AuditRetry` records who requested a retry/rerun.

## Job queue (`jobs/queue.py`, `jobs` table)

| Characteristic | Delayed Job (Ruby)                                       | Python                                                                                                                              |
|----------------|----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| Scheduling     | `run_at`                                                 | `run_at`                                                                                                                            |
| Queues         | `0..9` (by `github_pr_id % 10`) and named                | same (`queue` text); the worker accepts `--queues`                                                                                  |
| Reservation    | optimistic `UPDATE … locked_at`                          | `SELECT … FOR UPDATE SKIP LOCKED` + `locked_at/locked_by` (test with 4 workers × 40 jobs: no job runs twice)                        |
| Failure        | `attempts += 1`, `run_at = now + 5 + attempts**4` s      | identical                                                                                                                           |
| Limit          | `max_attempts = 5`, then removes (`destroy_failed_jobs`) | `max_attempts` per job (default 5), then removes                                                                                    |
| Timeout        | `max_run_time = 5 min`                                   | 5 min alarm in the worker process (`SIGALRM`), the job fails and is rescheduled; an expired lock also lets another worker take over |
| Debounce       | `destroy_all` by `handler LIKE` + new job                | `replace_pending(handler, dedupe_key, queue)` removes only **unstarted** jobs and schedules +30 s                                   |

Asynchronous flows: `create_execution_by_plan|comment|command`, `ci_job_status`, `timeout_execution`, `fetch_topotest_failures`, `slack_username_to_id`.

## Concurrency

- **Per PR**: `ci_job_status` uses the `github_pr_id % 10` queue; with one worker per queue range (Ansible), updates for the same PR are serialized.
- **Creating/canceling executions**: PostgreSQL advisory lock per pull request (`pg_advisory_lock`, dedicated connection) in `CreateExecutionBy*`; two rapid events on the same PR do not compete to cancel/create suites.
- **Web**: uvicorn with N processes; state only in the database; metrics aggregated via mmap files in `PROMETHEUS_MULTIPROC_DIR`.
- **GitHub token**: protected by a per-App `threading.Lock`; single renewal even with concurrent requests.

## Idempotency and retries

| Operation                                                       |          Idempotent?           | Policy                                                                                                                                                                                               |
|-----------------------------------------------------------------|:------------------------------:|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Check run `PATCH`, `GET`s, reactions                            |              yes               | up to `GITHUB_MAX_RETRIES` retries on transient failure; check run "not yet visible" (404) retried 3× with 5/10/15/20 s (same as Ruby)                                                               |
| Check run `POST`, plan `POST` in Bamboo, comments               |               no               | **no automatic retry**; `create_execution_by_*` with 1 attempt                                                                                                                                       |
| `/update/status` callback                                       | yes (304 guard per transition) | Bamboo can resend without a duplicate effect                                                                                                                                                         |
| `ci_job_status`, `timeout_execution`, `fetch_topotest_failures` | yes (recompute from the state) | 5 attempts with back-off                                                                                                                                                                             |
| Duplicate webhook                                               |           partially            | no protection by default; `WEBHOOK_DEDUPE_TTL_SECONDS` enables deduplication by `X-GitHub-Delivery`. A repeated `synchronize` creates a new execution and cancels the previous one (the newest wins) |

## Failures and recovery

- **GitHub unavailable/rate limit:** 5xx/limit responses → retries with `Retry-After` (max. 60 s); if it persists, the job fails, retries (back-off) or is discarded with `last_error` recorded and an `ERROR` log.
- **Bamboo unavailable:** the client returns `None` (as in Ruby); plan not started → `418`/status recorded and **no** stage created; `Finished` responds `503` without changing state.
- **Slack unavailable:** never propagates; metric `slack_notifications_total{status="error"}`.
- **Database:** `pool_pre_ping`; workers survive loop errors and keep going.
- **"Stuck" executions:** `timeout_execution` (30 min; 2 h without updates → `Finished` *hanged*), the `watch-dog` and `pr-bamboo-sync` timers reconcile with Bamboo; `single-sync <PLAN-123>` for one-off cases.
- **Restarts:** `Restart=always`; reserved jobs whose lock expires (5 min) return to the queue.
