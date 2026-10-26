# 09 — Operations: logs, health, metrics and troubleshooting

## Processes (systemd, installed by Ansible)

| Unit                                                | Role                                                           |
|-----------------------------------------------------|----------------------------------------------------------------|
| `netdef-ci-web.service`                             | uvicorn (`--factory netdef_ci.web.app:app_factory`, N workers) |
| `netdef-ci-worker-q0-3`, `-q4-6`, `-q7-9`, `-named` | job workers by queue range                                     |
| `netdef-ci-watchdog.timer` / `.service`             | `python -m netdef_ci watch-dog`                                |
| `netdef-ci-pr-sync.timer` / `.service`              | `python -m netdef_ci pr-bamboo-sync` (optional)                |
| `netdef-ci.target`                                  | groups everything: `systemctl restart netdef-ci.target`        |

## Logs

- Default: stdout → journald (`journalctl -u 'netdef-ci-*' -f`, `-u netdef-ci-web`).
- `LOG_DIR` (Ansible: `/var/log/netdef-ci`, `netdef_ci_file_logging`): `github_app.log` and a **`pr<N>.log` per pull request** (start there to debug a PR); rotation via `/etc/logrotate.d/netdef-ci`.
- Secrets are redacted (see `04`). DEBUG level: `DEBUG=true` and restart.
- Each log line carries the component (`netdef_ci.github_update_status`, `…github_build_summary`, `…ci_job_status`, etc.), analogous to the Ruby files.

## Health checks

| Endpoint                                       | Use                                                     |
|------------------------------------------------|---------------------------------------------------------|
| `GET /ping`, `GET /healthz`                    | liveness                                                |
| `GET /readyz`                                  | readiness: runs `SELECT 1`; `503` if the database fails |
| `ansible-playbook … playbooks/healthcheck.yml` | readiness + liveness + state of each unit               |
| `python -m netdef_ci check-config`             | configuration/keys/credentials/database                 |

## Metrics and alerts

`GET /metrics` (Basic Auth). Suggestions: `delayed_jobs_pending` growing, `delayed_jobs_locked_too_long > 0`, `delayed_jobs_max_attempts_reached > 0`, `app_exceptions_total`, `ci_job_timeout_total`, `bamboo_api_requests_total{status="error"}`, `github_api_requests_total{status="5xx"}`, `ci_stages_total{status="in_progress"}` stuck.
The Ruby project's `grafana_dashboard.json` remains usable, except for the `puma_*`/`http_server_*` panels (see `07`).

## Troubleshooting

| Symptom                                                                    | Check / action                                                                                                                                |
|----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| Webhook returns `404 Signature not found` / `401 Signatures didn't match!` | secret differs between GitHub/Bamboo and `WEBHOOK_SECRET`; proxy rewriting the body (the signature is computed over the raw body)             |
| PR without check runs, response `422 No Plans associated…`                 | missing row in `plans` (`github_repo_name = '<org>/<repo>'`)                                                                                  |
| Check runs do not appear; log "Github Authentication Failed"               | `GITHUB_APPS_FILE`, `.pem` path/permissions, App installed on the repository; `check-config`                                                  |
| `create_execution_by_plan` has no effect                                   | `SELECT * FROM jobs`; are the `named` workers active? (`systemctl status netdef-ci-worker-named`); PR log                                     |
| Plan does not start: `Failed to create CI Plan` in the log (429/418/4xx)   | Bamboo concurrent build limit (429), Bamboo/`127.0.0.1` tunnel down (418), credentials                                                        |
| Stage stuck in `in_progress`                                               | `python -m netdef_ci single-sync PROJ-PLAN-123` or wait for the `watch-dog`; check Bamboo callbacks (`/update/status`) and `signature_secret` |
| `jobs` with high `attempts` / `last_error`                                 | `SELECT id, handler, attempts, last_error FROM jobs WHERE attempts > 0;`                                                                      |
| `/metrics` 401                                                             | `METRICS_USERNAME/PASSWORD` not set (inherited behavior)                                                                                      |
| Slack silent                                                               | `SLACK_BOT_URL` and credentials; `slack_notifications_total{status="error"}`; `SLACK_BOT_VERIFY_TLS`                                          |
| Metrics reset to zero after deploy                                         | `PROMETHEUS_MULTIPROC_DIR` must be local and writable by all processes                                                                        |

Useful commands: `python -m netdef_ci purge-jobs` (equivalent to `rake jobs:clear`), `python -m netdef_ci org|user …` (console), `python -m netdef_ci migrate`.
