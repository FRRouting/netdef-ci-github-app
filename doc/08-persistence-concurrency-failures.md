# 08 — Persistence, concurrency, idempotency and failure handling

## Persistence

- PostgreSQL (schema in `06`). Short SQLAlchemy sessions, with an explicit `commit` on every state change: if a job dies midway, what has already been written stays consistent with what has already been sent to GitHub/Bamboo.
- Dates in "naive" UTC (`timestamp without time zone`).
- `AuditStatus` records each transition of `CiJob`/`Stage` (with the agent: `Github` or `WatchDog`); `AuditRetry` records who requested a retry/rerun.

## Job queue (`jobs/queue.py`, `jobs` table)

| Characteristic | Behaviour                                                                                                                           |
|----------------|-------------------------------------------------------------------------------------------------------------------------------------|
| Scheduling     | `run_at`                                                                                                                            |
| Queues         | `0..9` (by `github_pr_id % 10`) and named (`queue` text); the worker accepts `--queues`                                             |
| Reservation    | `SELECT … FOR UPDATE SKIP LOCKED` + `locked_at/locked_by` (test with 4 workers × 40 jobs: no job runs twice)                        |
| Failure        | `attempts += 1`, `run_at = now + 5 + attempts**4` s                                                                                 |
| Limit          | `max_attempts` per job (default 5), then removes                                                                                    |
| Timeout        | 5 min alarm in the worker process (`SIGALRM`), the job fails and is rescheduled; an expired lock also lets another worker take over |
| Debounce       | `replace_pending(handler, dedupe_key, queue)` removes only **unstarted** jobs and schedules +30 s                                   |

Asynchronous flows: `create_execution_by_plan|comment|command`, `setup_github_checks`, `retry_execution`, `ci_job_status`, `finished_execution`, `timeout_execution`, `fetch_topotest_failures`, `slack_username_to_id`.
Their delays, re-schedules and the periodic timers are listed in `09-operations.md` ("Background job schedule").

## Concurrency

- **Per PR**: `ci_job_status` uses the `github_pr_id % 10` queue; with one worker per queue range (Ansible), updates for the same PR are serialized.
- **Creating/canceling executions**: PostgreSQL advisory lock per pull request (`pg_advisory_lock`, dedicated connection) in `CreateExecutionBy*`; two rapid events on the same PR do not compete to cancel/create suites. Inside the lock, the new execution is submitted only after Bamboo confirms that the previous one stopped, or after `EXECUTION_CANCEL_WAIT_MAX_SECONDS` (60 s, then an `ERROR` is logged). Bamboo is stopped before any GitHub call, so a GitHub error cannot keep the previous build running.
- **`ci:retry` / `ci:rerun` admission** (`services/command_guard.py`): one command at a time per pull request and none again within `CI_COMMAND_COOLDOWN_SECONDS`; concurrent webhooks of one pull request wait for each other on a transaction-scoped advisory lock (`pg_advisory_xact_lock`, held only while checking and enqueuing). A duplicate request gets `409` instead of stopping the build the first one started. The `retry_execution` job re-reads the rows after taking the pull request lock.
- **Web**: uvicorn with N processes; state only in the database; metrics aggregated via mmap files in `PROMETHEUS_MULTIPROC_DIR`.
- **GitHub token**: protected by a per-App `threading.Lock`; single renewal even with concurrent requests.

## Idempotency and retries

| Operation                                                       |          Idempotent?           | Policy                                                                                                                                                                                                                                                                                                                                |
|-----------------------------------------------------------------|:------------------------------:|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Check run `PATCH`, `GET`s, reactions                            |              yes               | up to `GITHUB_MAX_RETRIES` retries on transient failure; check run "not yet visible" (404) or update not kept by GitHub retried 3× with 1/2/4 s                                                                                                                                                                                       |
| Check run `POST`, plan `POST` in Bamboo, comments               |               no               | **no automatic retry**; `create_execution_by_*` and `retry_execution` with 1 attempt; a `create_execution_by_plan` that failed GitHub authentication before writing anything schedules itself again (see "Phases of an execution")                                                                                                    |
| `setup_github_checks` (GitHub side of a started execution)      |  yes (resumes the same suite)  | 5 attempts with back-off, first one +10 s (callbacks are dropped until it creates the CI jobs); never creates a suite nor starts/stops Bamboo                                                                                                                                                                                         |
| `/update/status` callback                                       | yes (304 guard per transition) | Bamboo can resend without a duplicate effect                                                                                                                                                                                                                                                                                          |
| `ci_job_status`, `timeout_execution`, `fetch_topotest_failures` | yes (recompute from the state) | 5 attempts with back-off                                                                                                                                                                                                                                                                                                              |
| Duplicate webhook                                               |           partially            | no protection in the code defaults; `WEBHOOK_DEDUPE_TTL_SECONDS` (2 days in Ansible) enables deduplication by `X-GitHub-Delivery`. A repeated `synchronize` creates a new execution and cancels the previous one (the newest wins); duplicate `ci:retry`/`ci:rerun` requests (new delivery ids) are refused by `CommandGuard` (`409`) |

## Phases of an execution

`create_execution_by_plan`, `create_execution_by_comment` and `create_execution_by_command` run with one attempt,
because they start a Bamboo plan. Their work is split so that a failure part-way never leaves a started build that
nothing tracks, nor a pull request without a build:

| Phase                                                     | What it does                                                                                                                                                                                                                                                                                                                                                                       | On failure                                                                                                                                                                                                                                                                                                            |
|-----------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1. Authenticate (`create_execution_by_plan`)              | The new CheckSuite is built with its `plan_id`, the GitHub client authenticates, and only then the suite is committed                                                                                                                                                                                                                                                              | `GithubAuthError` (DNS, timeouts, refused token): rollback, nothing is left in the database and Bamboo is not called. The same job is enqueued again (`attempt + 1`, +`5 + attempt⁴` s, still one attempt each) up to `JOB_MAX_ATTEMPTS`; a retry is dropped (`409 Superseded`) when a newer suite of the plan exists |
| 2. Stop the previous execution (Bamboo)                   | Previous execution = newest suite of the PR and plan (or without plan) **with** a `bamboo_ci_ref`. It is stopped when a stage is queued/in progress, or when it has no stage and no CI job and Bamboo does not report it stopped. Its running CI jobs without a check run are cancelled in the database, then `stopPlan` and `wait_until_stopped`                                  | Bamboo helpers log and return; after `EXECUTION_CANCEL_WAIT_MAX_SECONDS` the new plan starts anyway                                                                                                                                                                                                                   |
| 3. Start the plan (Bamboo)                                | `PlanRun.start_plan`, stores `bamboo_ci_ref`, comments on the build                                                                                                                                                                                                                                                                                                                | no `buildResultKey`: `418`/`429`/`4xx` status, no stage is created                                                                                                                                                                                                                                                    |
| 4. GitHub setup (`services/checks_setup.py::ChecksSetup`) | Slack "execution started" (first run only, best effort); cancels the open stages (and CI jobs with a check run) of the stopped executions; "cancelled due to a new commit" comment on their Bamboo builds (once, guarded by `cancelled_previous_check_suite_id`); stages, CI jobs and check runs of the new suite; timeout job; for reruns, jobs removed from the plan are skipped | Any exception is logged with the suite id and `bamboo_ci_ref` and `setup_github_checks(check_suite_id, plan_id, previous_check_suite_ids, rerun)` is enqueued on the creation job's own queue (`execution_queue`); the creation job ends normally (`202`)                                                             |

`setup_github_checks` takes the pull request lock, re-reads the rows and resumes the same suite
(`Action.create_summary(resume=True)`): an existing stage only gets its missing check run or its `in_progress`
transition, existing CI jobs (same `job_ref`) are not created again, and the timeout job is not scheduled twice
(`dedupe_key` `suite-<id>`). When a newer suite of the same PR and plan was started in Bamboo, it only cancels the open
check runs of the executions it had stopped and returns (`Superseded`). When the suite no longer exists it returns
`404` without raising. After `JOB_MAX_ATTEMPTS` failures the job is removed with `last_error`; the next push treats the
suite as running (no stages) and stops its build.

Late Bamboo callbacks of the stopped build cannot undo the cancellation: its CI jobs are closed in the database before
the stop, per-job callbacks only schedule summary work (`ci_job_status`, +30 s debounce) for the current execution of
the plan, and a `finished_execution` for the stopped suite finds its jobs closed. When it still concludes a stage
first, ChecksSetup finds that stage closed and skips it; the worst case of the two running at the same moment is the
same check run concluded twice.

## Failures and recovery

- **GitHub unavailable/rate limit:** 5xx/limit responses → retries with `Retry-After` (max. 60 s); if it persists, the job fails, retries (back-off) or is discarded with `last_error` recorded and an `ERROR` log. While creating an execution, a GitHub failure before the Bamboo start leaves nothing behind and is retried; one after it defers the GitHub setup to `setup_github_checks` (see above).
- **Bamboo unavailable:** the client returns `None`; plan not started → `418`/status recorded and **no** stage created; `Finished` responds `503` without changing state.
- **Slack unavailable:** never propagates; metric `slack_notifications_total{status="error"}`.
- **Database:** `pool_pre_ping`; workers survive loop errors and keep going.
- **"Stuck" executions:** `timeout_execution` (every 10 min; 2 h without updates → `Finished` *hanged*), the `watch-dog` and `pr-bamboo-sync` timers reconcile with Bamboo; `single-sync <PLAN-123>` for one-off cases.
- **Restarts:** `Restart=always`; reserved jobs whose lock expires (5 min) return to the queue.
