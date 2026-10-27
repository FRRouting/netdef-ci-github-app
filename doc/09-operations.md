# 09 — Operations: logs, health, metrics and troubleshooting

## Processes (systemd, installed by Ansible)

| Unit                                                                                                   | Role                                                           |
|--------------------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| `netdef-ci-web.service`                                                                                | uvicorn (`--factory netdef_ci.web.app:app_factory`, N workers) |
| `netdef-ci-worker-q0-3`, `-q4-6`, `-q7-9`                                                              | job workers by queue range                                     |
| `netdef-ci-worker-create-by-plan`, `-create-by-comment`, `-create-by-command`, `-timeout`, `-topotest` | one job worker per named queue                                 |
| `netdef-ci-watchdog.timer` / `.service`                                                                | `python -m netdef_ci watch-dog`                                |
| `netdef-ci-pr-sync.timer` / `.service`                                                                 | `python -m netdef_ci pr-bamboo-sync` (optional)                |
| `netdef-ci.target`                                                                                     | groups everything: `systemctl restart netdef-ci.target`        |

## Background job schedule

Defaults below; the environment variable (see `04`) or Ansible variable that changes each value is in parentheses.

### Worker loop (`jobs/queue.py`)

| What                  | Interval                                                                                                          |
|-----------------------|-------------------------------------------------------------------------------------------------------------------|
| Idle polling          | a worker that finds no ready job (`run_at <= now`) waits **5 s** before polling again (`JOB_SLEEP_DELAY_SECONDS`) |
| Busy loop             | after running a job the worker polls again immediately, so a backlog drains without waiting                       |
| Run time limit / lock | **300 s** (`JOB_MAX_RUN_TIME_SECONDS`): `SIGALRM` fails the job; a lock older than that is taken over             |
| Retry back-off        | `run_at = now + 5 + attempts⁴` s, up to **5** attempts (`JOB_MAX_ATTEMPTS`), then the job is removed              |

Back-off with the defaults: 1st failure → +6 s, 2nd → +21 s, 3rd → +86 s, 4th → +261 s (≈ 4.4 min), 5th → removed
(≈ 6.2 min between the first run and the removal, plus run times). Jobs enqueued with `max_attempts=1` (the
`create_execution_by_*` jobs, which start a Bamboo plan) are removed at the first failure and never retried.

### Delayed jobs (enqueued with a `run_at` in the future)

| Handler (queue)                                                           | Enqueued by                          | Runs                                                                                                                                                                                                                                          |
|---------------------------------------------------------------------------|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `create_execution_by_plan` (same name)                                    | PR webhook (`opened`/`synchronize`)  | **+5 s** (`CREATE_EXECUTION_DELAY_SECONDS`), one job per plan                                                                                                                                                                                 |
| `create_execution_by_comment`, `create_execution_by_command` (same names) | `ci:rerun` comment / suite re-run    | **+1 s** (`RERUN_DELAY_SECONDS`), one job per plan                                                                                                                                                                                            |
| `ci_job_status` (`github_pr_id % 10`)                                     | Bamboo callback `/update/status`     | **+30 s** (`STATUS_DEBOUNCE_SECONDS`); a new callback for the same suite replaces the pending job, so the summary is rebuilt 30 s after the **last** callback of a burst                                                                      |
| `timeout_execution` (same name)                                           | execution start                      | **+10 min** (`TIMEOUT_CHECK_MINUTES`), then re-enqueues itself every 10 min while the suite is unfinished; a suite without updates for **2 h** (`TIMEOUT_HANG_HOURS`) is finished as *hanged* (detected 2 h–2 h 10 min after the last update) |
| `fetch_topotest_failures` (same name)                                     | failed job callback without failures | **+5 min** (fixed); while Bamboo returns no failures it re-enqueues itself at +10 min, +15 min and +20 min (`5 × count` min). The 4th attempt (count 4, ≈ 50 min after the callback) only queries Bamboo and stops without storing            |

`slack_username_to_id` has a handler but nothing enqueues it today (the `console` CLI runs the task directly).

### Periodic tasks (systemd timers, `netdef_ci_timers`)

| Timer                      | Command          | Default calendar                 | Notes                                                                                 |
|----------------------------|------------------|----------------------------------|---------------------------------------------------------------------------------------|
| `netdef-ci-watchdog.timer` | `watch-dog`      | `*:0/15` (every 15 min), enabled | reconciles every suite with `queued`/`in_progress` stages via `Finished`              |
| `netdef-ci-pr-sync.timer`  | `pr-bamboo-sync` | `hourly`, **disabled**           | compares suites created between 24 h and 2 h ago with Bamboo and fixes the stale ones |

Both timers use `Persistent=true` (a run missed while the host was down happens at boot) and `RandomizedDelaySec=30`
(each run starts up to 30 s late). `single-sync <PLAN-123>` has no timer: it is run by hand.

### Waits inside a job

These sleep inside the running job and count towards the 300 s limit:

| Where                                      | Wait                                                                                               |
|--------------------------------------------|----------------------------------------------------------------------------------------------------|
| Running plan lookup (`services/common.py`) | polls every **3 s** (`RUNNING_PLAN_POLL_SECONDS`) for up to **60 s** (`RUNNING_PLAN_WAIT_SECONDS`) |
| Bamboo build log (`clients/bamboo.py`)     | up to 4 downloads, **5 s** apart                                                                   |
| GitHub check run completion                | up to 3 retries after 5 s, 10 s and 15 s when the check run is not visible or not updated yet      |
| HTTP retries (`clients/http.py`)           | `min(2^attempt, 10)` s, or the server's `Retry-After` on rate limits                               |

## Logs

- Default: stdout → journald (`journalctl -u 'netdef-ci-*' -f`, `-u netdef-ci-web`).
- `LOG_DIR` (Ansible: `/var/log/netdef-ci`, `netdef_ci_file_logging`): `github_app.log` and a **`pr<N>.log` per pull request** (start there to debug a PR); rotation via `/etc/logrotate.d/netdef-ci`.
- Secrets are redacted (see `04`). DEBUG level: `DEBUG=true` and restart.
- Each log line carries the component (`netdef_ci.github_update_status`, `…github_build_summary`, `…ci_job_status`, etc.).

## Health checks

| Endpoint                                       | Use                                                     |
|------------------------------------------------|---------------------------------------------------------|
| `GET /ping`, `GET /healthz`                    | liveness                                                |
| `GET /readyz`                                  | readiness: runs `SELECT 1`; `503` if the database fails |
| `ansible-playbook … playbooks/healthcheck.yml` | readiness + liveness + state of each unit               |
| `python -m netdef_ci check-config`             | configuration/keys/credentials/database                 |

## Metrics and alerts

`GET /metrics` (Basic Auth). Suggestions: `delayed_jobs_pending` growing, `delayed_jobs_locked_too_long > 0`, `delayed_jobs_max_attempts_reached > 0`, `app_exceptions_total`, `ci_job_timeout_total`, `bamboo_api_requests_total{status="error"}`, `github_api_requests_total{status="5xx"}`, `ci_stages_total{status="in_progress"}` stuck.

## Troubleshooting

| Symptom                                                                    | Check / action                                                                                                                                |
|----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| Webhook returns `404 Signature not found` / `401 Signatures didn't match!` | secret differs between GitHub/Bamboo and `WEBHOOK_SECRET`; proxy rewriting the body (the signature is computed over the raw body)             |
| PR without check runs, response `422 No Plans associated…`                 | missing row in `plans` (`github_repo_name = '<org>/<repo>'`)                                                                                  |
| Check runs do not appear; log "Github Authentication Failed"               | `GITHUB_APPS_FILE`, `.pem` path/permissions, App installed on the repository; `check-config`                                                  |
| `create_execution_by_plan` has no effect                                   | `SELECT * FROM jobs`; is its worker active? (`systemctl status netdef-ci-worker-create-by-plan`); PR log                                      |
| Plan does not start: `Failed to create CI Plan` in the log (429/418/4xx)   | Bamboo concurrent build limit (429), Bamboo/`127.0.0.1` tunnel down (418), credentials                                                        |
| Stage stuck in `in_progress`                                               | `python -m netdef_ci single-sync PROJ-PLAN-123` or wait for the `watch-dog`; check Bamboo callbacks (`/update/status`) and `signature_secret` |
| `jobs` with high `attempts` / `last_error`                                 | `SELECT id, handler, attempts, last_error FROM jobs WHERE attempts > 0;`                                                                      |
| `/metrics` 401                                                             | `METRICS_USERNAME/PASSWORD` not set (inherited behavior)                                                                                      |
| Slack silent                                                               | `SLACK_BOT_URL` and credentials; `slack_notifications_total{status="error"}`; `SLACK_BOT_VERIFY_TLS`                                          |
| Metrics reset to zero after deploy                                         | `PROMETHEUS_MULTIPROC_DIR` must be local and writable by all processes                                                                        |

Useful commands: `python -m netdef_ci purge-jobs`, `python -m netdef_ci org|user …` (console), `python -m netdef_ci migrate`.

## Checking the Bamboo connection from code

`python -m netdef_ci check-bamboo [--plan PROJ-PLAN] [--result PROJ-PLAN-123]` uses the service's own Bamboo client (same `BAMBOO_BASE_URL`, credentials and TLS setting) and issues read-only GET requests: server info, optionally a plan and an execution (with its status and job count). It prints `ok`/`FAIL` per call with the HTTP status or the connection error and exits non-zero on any failure. Run it with the service environment, e.g. `sudo -u netdef-ci bash -c 'set -a; . /etc/netdef-ci/netdef-ci.env; set +a; cd /opt/netdef-ci/current && PYTHONPATH=src venv/bin/python -m netdef_ci check-bamboo --result PROJ-PLAN-123'`.
