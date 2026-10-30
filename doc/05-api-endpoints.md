# 05 — Endpoints and examples

All examples use **fictitious** values. Computing the signature:

```bash
BODY='{"action":"opened", ...}'
SIG="sha256=$(printf %s "$BODY" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | sed 's/^.* //')"
```

| Method and route                      | Authentication                              | Body / purpose                                                                      |
|---------------------------------------|---------------------------------------------|-------------------------------------------------------------------------------------|
| `POST /` and `POST /<any path>`       | HMAC (`X-Hub-Signature-256` or `Signature`) | GitHub webhook; event in `X-GitHub-Event`                                           |
| `POST /update/status`                 | HMAC                                        | Bamboo callback                                                                     |
| `POST /slack`, `POST /slack/settings` | Basic (Slack bot credentials)               | Slack commands                                                                      |
| `GET /metrics`                        | Basic (`METRICS_*`)                         | Prometheus                                                                          |
| `GET /ping`                           | —                                           | `200 Pong`                                                                          |
| `GET /healthz`                        | —                                           | liveness `{"status":"ok"}`                                                          |
| `GET /readyz`                         | —                                           | readiness (queries the database): `200 {"status":"ready","database":"ok"}` or `503` |
| `GET /telemetry`                      | —                                           | `{"version","uptime_seconds","db_pool"}`                                            |

## GitHub webhooks (`POST /`)

| Event               | Condition                                                               | Response                                                                                                                                                             |
|---------------------|-------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ping`              | —                                                                       | `200 PONG!`                                                                                                                                                          |
| `pull_request`      | `action` ∈ opened/synchronize/reopened                                  | `200 Scheduled Plan Runs` (one job per plan) · `422 No Plans associated with this Pull Request` · other actions `405 Not dealing with action "<a>" for Pull Request` |
| `check_run`         | `action == rerequested`                                                 | `404 Stage not found` · `406 Already enqueued this execution` · `406 <reason>` (execution still running) · `200 Retrying failure jobs`; other action `200 OK`        |
| `issue_comment`     | body contains `ci:retry`                                                | same responses as retry                                                                                                                                              |
| `issue_comment`     | body contains `ci:rerun` (or `ci:rerun #<sha>`) and `action == created` | `200 Scheduled Plan Runs` · `404 Pull Request not found` · `404 Can not rerun a new PullRequest` · `404 Action not found`                                            |
| `issue_comment`     | other text                                                              | `200 Just a comment`; without `comment` → `404 Action not found`                                                                                                     |
| `check_suite`       | `action` contains `rerequested`                                         | `200 Scheduled Plan Runs` · `404 Failed to fetch a check suite`; other action `200 OK`                                                                               |
| `installation`      | —                                                                       | `202 Updated`                                                                                                                                                        |
| other               | —                                                                       | `401 Invalid request (4)`                                                                                                                                            |
| no `X-GitHub-Event` | —                                                                       | `400 Missing X-GitHub-Event header`                                                                                                                                  |

Common errors: no signature `404 Signature not found`; wrong signature `401 Signatures didn't match!`; invalid JSON (after authentication) `400`; internal failure `500 {"error":"Internal Server Error"}` (no details). Content-Type: `text/plain; charset=utf-8`.

Example (`pull_request`, sanitized):

```bash
curl -sS https://ci.example.invalid/githubcheck -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: pull_request' -H "X-Hub-Signature-256: $SIG" --data-binary "$BODY"
# 200 Scheduled Plan Runs
```
```json
{"action":"synchronize","number":7,"repository":{"full_name":"example-org/example-repo"},
 "pull_request":{"user":{"login":"alice","id":4242},"head":{"ref":"feature","sha":"1111111111111111111111111111111111111111"},
                 "base":{"ref":"main","sha":"2222222222222222222222222222222222222222"}}}
```

## Bamboo callback (`POST /update/status`)

Payload: `status` (`in_progress` | `success` | `failure` | `finished` | other → treated as failure), `bamboo_ref` (job or plan key), optional `failures` (`[{suite, case, message, execution_time}]`), `output.summary` and `timestamp` (Unix seconds; required when `BAMBOO_CALLBACK_MAX_AGE_SECONDS > 0`, see 04).

| Situation                                                                                                                     | Response                                                                                      |
|-------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| missing or out-of-window `timestamp` (only with `BAMBOO_CALLBACK_MAX_AGE_SECONDS > 0`)                                        | `401 Stale or missing timestamp`                                                              |
| body already processed (only with `BAMBOO_CALLBACK_MAX_AGE_SECONDS > 0`)                                                      | `200 Duplicate callback ignored`                                                              |
| unknown job                                                                                                                   | `404 CI JOB not found`                                                                        |
| job `queued` and status ≠ `in_progress` (except the `Checkout Code` job) or job `in_progress` and status ∉ {success, failure} | `304 Not Modified` (no body)                                                                  |
| updated                                                                                                                       | `200 Success`                                                                                 |
| error while updating                                                                                                          | `500 Internal Server Error`                                                                   |
| `status == finished`                                                                                                          | `200 Finished` · `200 Still running` · `404 Check Suite not found` · `503 Bamboo unavailable` |

The `Content-Type` is `application/json` even with a text body.

```bash
curl -sS https://ci.example.invalid/update/status -H "Signature: $SIG" --data-binary \
  '{"status":"failure","bamboo_ref":"PROJ-PLAN-JOB1-42","output":{"summary":"Checkout failed"},"failures":[{"suite":"bgp","case":"test_x","message":"assert 0","execution_time":3}]}'
# 200 Success
```

## Slack

`POST /slack` with `Authorization: Basic …`:

- with the `event` key → table of the author's PRs (`github_user`) with running jobs, or "No running PR";
- without `event` → subscription: `{"rule":"notify|user","target":"12","notification":"all|errors|pass|off","slack_user_id":"U1"}` → `Subscription created | Subscription updated | Unsubscribed | Invalid GitHub username`.

`POST /slack/settings` `{"slack_user_id":"U1"}` → table of subscriptions or `You don't have any subscription`. Without valid credentials: `401`.

## Metrics (`GET /metrics`)

`http_requests_total`, `http_request_duration_seconds`, `github_webhook_events_total`, `app_exceptions_total{class,handler}`,
`bamboo_api_requests_total`, `bamboo_api_request_duration_seconds`, `slack_notifications_total`, `ci_job_execution_seconds`, `ci_job_retry_total`,
`ci_job_timeout_total`, `activerecord_queries_total`, `activerecord_query_duration_seconds`, gauges `delayed_jobs_*` (computed over the `jobs` table),
`ci_jobs_total`, `ci_stages_total`, `activerecord_connection_pool_*` (including `_waiting`, always 0), `http_server_requests_total`,
`http_server_request_duration_seconds`, `http_server_exceptions_total`, the web-worker gauges `puma_workers_total`, `puma_booted_workers`,
`puma_running_threads`, `puma_pool_capacity`, `puma_max_threads`, `puma_backlog` (simplified, see `07-design-notes.md`) and `github_api_requests_total`.
