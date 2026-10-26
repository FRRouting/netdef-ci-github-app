# 04 — Configuration, GitHub App, authentication and secrets

Configuration comes from **environment variables** (or a `.env` file in the root, for development only) read by
`pydantic-settings` (`src/netdef_ci/config.py`). `/.env.example` lists everything with **dummy** values; never commit the real
`.env`. The GitHub Apps live in a TOML file pointed to by `GITHUB_APPS_FILE` (`github_apps.example.toml`).
Unlike Ruby, changes require **restarting** the services (`debug` is not reloaded on every request).

## Environment variables

| Variable                                                 |       Required       | Default (non-sensitive)                                                           | Purpose / Ruby equivalent                                                                                                 |
|----------------------------------------------------------|:--------------------:|-----------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `NETDEF_ENV`                                             |          no          | `development`                                                                     | `development` \| `production` \| `test`. In `production` the app does not start without `WEBHOOK_SECRET` (`RACK_ENV`)     |
| `DEBUG`                                                  |          no          | `false`                                                                           | DEBUG logs (`debug` in config.yml)                                                                                        |
| `LOG_DIR`                                                |          no          | *(empty)*                                                                         | writes `github_app.log` and `pr<N>.log` (one per PR) in that directory, in addition to stdout/journald                    |
| `DATABASE_URL`                                           |       **yes**        | `postgresql+psycopg://postgres:postgres@localhost:5432/githubruns-dev` (dev only) | PostgreSQL (`config/database.yml`)                                                                                        |
| `DB_POOL_SIZE`                                           |          no          | `10`                                                                              | pool (`pool: 10`)                                                                                                         |
| `WEBHOOK_SECRET`                                         | **yes** (production) | —                                                                                 | HMAC-SHA256 secret for GitHub and Bamboo (`auth_signature.password`); ≥ 16 characters in the deployment                   |
| `WEBHOOK_DEDUPE_TTL_SECONDS`                             |          no          | `0`                                                                               | `>0` ignores repeated `X-GitHub-Delivery` deliveries within the window (new; `0` = Ruby behavior)                         |
| `METRICS_USERNAME` / `METRICS_PASSWORD`                  |         no*          | —                                                                                 | Basic Auth for `/metrics` (`metrics_auth`). *Without them `/metrics` always responds 401, as in Ruby                      |
| `GITHUB_APPS_FILE`                                       |       **yes**        | —                                                                                 | TOML with `[[github_apps]]` (`login`, `cert`, `repo`)                                                                     |
| `GITHUB_API_URL`                                         |          no          | `https://api.github.com`                                                          | GitHub API (GHES)                                                                                                         |
| `GITHUB_APP_NAME`                                        |          no          | `NetDEF CI Hook`                                                                  | App name: its check runs outside the stage list are marked `skipped`                                                      |
| `GITHUB_MAX_RETRIES`                                     |          no          | `3`                                                                               | extra (bounded) attempts for transient failures/rate limit                                                                |
| `BAMBOO_BASE_URL`                                        |          no          | `https://127.0.0.1`                                                               | Ruby always called `https://127.0.0.1`                                                                                    |
| `BAMBOO_VERIFY_TLS`                                      |          no          | `false`                                                                           | Ruby used `VERIFY_NONE`                                                                                                   |
| `BAMBOO_USERNAME` / `BAMBOO_PASSWORD`                    |         no**         | —                                                                                 | Bamboo credentials. **If absent, uses `~/.netrc` (`BAMBOO_NETRC_MACHINE`, default `ci1.netdef.org`)                       |
| `CI_URL`                                                 |          no          | `ci1.netdef.org`                                                                  | host used in `https://<CI_URL>/browse/<KEY>` (also accepts `https://host`)                                                |
| `MULTI_PLAN`                                             |          no          | `false`                                                                           | plan suffix in stage names when the PR has several plans (`multi_plan?`)                                                  |
| `SLACK_BOT_URL`                                          |          no          | —                                                                                 | empty disables notifications (`slack_bot_url`)                                                                            |
| `SLACK_BOT_USERNAME` / `SLACK_BOT_PASSWORD`              |         no**         | —                                                                                 | **outgoing and incoming** credentials (`/slack`); `~/.netrc` fallback (`SLACK_BOT_NETRC_MACHINE`, `slack_bot.netdef.org`) |
| `SLACK_BOT_VERIFY_TLS`                                   |          no          | `true`                                                                            | Ruby did not verify TLS (see 07)                                                                                          |
| `HTTP_TIMEOUT_SECONDS`                                   |          no          | `30`                                                                              | HTTP clients timeout                                                                                                      |
| `JOB_MAX_ATTEMPTS`                                       |          no          | `5`                                                                               | `Delayed::Worker.max_attempts`                                                                                            |
| `JOB_MAX_RUN_TIME_SECONDS`                               |          no          | `300`                                                                             | `max_run_time` (aborts the job and releases the lock)                                                                     |
| `JOB_SLEEP_DELAY_SECONDS`                                |          no          | `5`                                                                               | `sleep_delay`                                                                                                             |
| `STATUS_DEBOUNCE_SECONDS`                                |          no          | `30`                                                                              | `DELAYED_JOB_TIMER`                                                                                                       |
| `CREATE_EXECUTION_DELAY_SECONDS` / `RERUN_DELAY_SECONDS` |          no          | `5` / `1`                                                                         | scheduling delays                                                                                                         |
| `TIMEOUT_CHECK_MINUTES` / `TIMEOUT_HANG_HOURS`           |          no          | `30` / `2`                                                                        | `TimeoutExecution`                                                                                                        |
| `PROMETHEUS_MULTIPROC_DIR`                               |          no          | `/tmp/prometheus_metrics`                                                         | local directory shared by web and workers (`PROMETHEUS_METRICS_DIR`); in Ansible: `/run/netdef-ci/prometheus`             |
| `CI_METRICS_WINDOW_HOURS`                                |          no          | `24`                                                                              | window of the `ci_jobs_total`/`ci_stages_total` gauges                                                                    |

Quick validation: `python -m netdef_ci check-config` (variables, `.pem` keys, Bamboo credentials and database connection).

### From `config.yml` / `database.yml` / `~/.netrc` to the new format

| Ruby                                                          | Python                                                                        |
|---------------------------------------------------------------|-------------------------------------------------------------------------------|
| `config.yml: auth_signature.password`                         | `WEBHOOK_SECRET`                                                              |
| `config.yml: github_apps[]`                                   | `github_apps.toml` (`[[github_apps]]`, same keys `login`, `cert`, `repo`)     |
| `config.yml: metrics_auth`                                    | `METRICS_USERNAME` / `METRICS_PASSWORD`                                       |
| `config.yml: slack_bot_url`, `ci.url`, `multi_plan?`, `debug` | `SLACK_BOT_URL`, `CI_URL` (host without `https://`), `MULTI_PLAN`, `DEBUG`    |
| `config.yml: port`, `redis`                                   | uvicorn `--port`; `redis` was legacy and was dropped                          |
| `config/database.yml`                                         | `DATABASE_URL`                                                                |
| `~/.netrc` (`ci1.netdef.org`, `slack_bot.netdef.org`)         | `BAMBOO_*` / `SLACK_BOT_*` (or the same `~/.netrc`, kept as a fallback)       |

## Development × production differences

| Aspect                 | Development                         | Production                                 |
|------------------------|-------------------------------------|--------------------------------------------|
| `NETDEF_ENV` / `DEBUG` | `development` / `true`              | `production` / `false`                     |
| Port                   | 9292 (like Ruby's dev `rackup`)     | 4667                                       |
| Web workers            | 2                                   | 4                                          |
| Database               | `githubruns-dev`                    | `githubruns-prod`                          |
| Timers                 | watch-dog on, pr-sync off           | both on                                    |
| Version                | free branch/commit                  | explicit tag/commit (`netdef_ci_version`)  |

## GitHub App configuration

Follow `doc/release/setup/github_app_setup.pdf` from the Ruby project (the existing App is still valid, **there is no need to create another one**):

1. Webhook URL: `https://<public-host>/<path>` — any path is accepted (`POST /*`); at NetDEF a reverse proxy serves `/githubcheck`. **Webhook secret** = `WEBHOOK_SECRET`. SSL verification enabled.
2. Repository permissions: **Metadata** (read, mandatory), **Checks**, **Issues**, **Pull requests** and **Discussions** (read and write). Used by the code: Checks (create/update check runs), Pull requests (PR info and commits), Issues (comments/`+1`/`-1` reactions on `ci:rerun`/`ci:retry`).
3. Subscribed events: **Check run**, **Check suite**, **Issue comment**, **Pull request** (required); *Discussion comment* and *Pull request review comment* are checked in the current App but are **not handled** (they respond 401 `Invalid request (4)`; no effect).
4. Generate the private key (`.pem`), install the App only on the desired repositories and register `login` (App ID) / `cert` / `repo` in `github_apps.toml`.
5. Register each repository's Bamboo plan in the `plans` table (`bamboo_ci_plan_name`, `github_repo_name`, `name`) and the stages in `stage_configurations` (`bamboo_stage_name`, `github_check_run_name`, `position`, `mandatory`, `can_retry`, `start_in_progress`). Without plans the PR receives `422 No Plans associated…` (there is no default plan in the code, contrary to what the deploy PDF says).
6. In the Bamboo plan, the notification script must sign the body with the `signature_secret` variable (sent by the app on every execution as `bamboo.variable.github_signature_secret`) and post to `/update/status` with the header `Signature: sha256=<hmac>`.

## Authentication, installation tokens and webhook signatures

- **Webhooks and callbacks:** HMAC-SHA256 of the **raw body** (bytes as received, before any parsing) with `WEBHOOK_SECRET`, compared with `hmac.compare_digest`. Response order identical to Ruby: empty body → 401; missing header → 404 `Signature not found`; mismatch → 401 `Signatures didn't match!`. Accepts `Signature` (takes precedence) or `X-Hub-Signature-256`.
- **GitHub App:** JWT RS256 (`iss` = App ID; `iat` backdated 60 s to tolerate clock skew; total validity ≤ 10 min) signed with the `.pem` key; `GET /app/installations` (first installation) and `POST /app/installations/{id}/access_tokens`. The **token is kept in memory and renewed 5 min before expiring**; a `401` invalidates the token and the call is repeated once. App selection: the `repo` from `github_apps.toml`; fallback to the first App that authenticates.
- **Slack/metrics:** Basic Auth with constant-time comparison.
- **Rate limit/network:** reads and `PATCH` retry up to `GITHUB_MAX_RETRIES` times on connection failures/502/503/504; any method retries on `429`/secondary limit honoring `Retry-After` (max 60 s). `POST` (check run creation) does **not** retry on network error.

## Secrets management and rotation

| Secret                                        | Where it lives                                                         | Rotation                                                                                                                                                                                                                                               |
|-----------------------------------------------|------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `WEBHOOK_SECRET`                              | Ansible Vault → `/etc/netdef-ci/netdef-ci.env` (0640 `root:netdef-ci`) | 1) change the value in the vault; 2) `deploy.yml` (restarts the services); 3) update the GitHub App *Webhook secret* and the Bamboo plan **in the same window** (running executions keep using the old secret in the callback: restart or re-run them) |
| GitHub App private key                        | vault → `/etc/netdef-ci/keys/<App ID>.pem`                             | generate a new key on GitHub, update the vault, `deploy.yml`, revoke the old one                                                                                                                                                                       |
| Bamboo / Slack / metrics / database passwords | vault → environment file                                               | update in the source service + vault + `deploy.yml`                                                                                                                                                                                                    |

No secret is written to logs: `logs.py` redacts `Bearer …`, `signature_secret=…`, `password/token/secret`, `gh*_…`, `sha256=<hex>` and private key blocks; the Bamboo submission URL (which contains the secret) is never logged.
