# 01 — Overview, architecture and structure

## Purpose and scope

`netdef-ci-github-app-python` is a standalone Python service. It connects **GitHub
Pull Requests** to an **Atlassian Bamboo CI** server:

1. receives GitHub events (PR opened/updated, `ci:retry` / `ci:rerun` comments, re-run from the Checks UI);
2. triggers a Bamboo plan for each plan configured for the repository;
3. creates and maintains GitHub **Check Runs** (one per *stage*) reflecting job progress;
4. receives Bamboo *callbacks* (`POST /update/status`) and reconciles state in the background (WatchDog, timeout);
5. notifies users on Slack and exposes Prometheus metrics.

Out of scope: ad-hoc report scripts and Redis-based queues (see `12-limitations-and-pending.md` and `09-operations.md`).

## Architecture

```mermaid
flowchart LR
    GH[(GitHub)] -- webhooks HMAC --> WEB[web<br/>FastAPI + uvicorn]
    BAM[(Bamboo CI)] -- POST /update/status HMAC --> WEB
    SL[(Slack bot)] -- /slack, /slack/settings Basic --> WEB
    PROM[(Prometheus)] -- GET /metrics Basic --> WEB
    WEB -- enqueues --> DB[(PostgreSQL<br/>schema + jobs)]
    W[job workers<br/>python -m netdef_ci worker] <--> DB
    WEB <--> DB
    W -- Check Runs / comments<br/>JWT + installation token --> GH
    WEB -- Check Runs --> GH
    W -- REST --> BAM
    W -- notifications --> SL
    T[systemd timers<br/>watch-dog / pr-bamboo-sync] --> DB
    T --> BAM
    T --> GH
```

| Component         | Responsibility                                                                                                                                | Code                            |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------|
| **web**           | Authenticates (HMAC/Basic), validates the raw body, delegates to the service and responds. Makes no slow external calls: it enqueues jobs.    | `web/app.py`, `web/webhooks.py` |
| **services**      | Business rules (BuildPlan, UpdateStatus, Summary, Finished, executions, retry, rerun, tasks).                                | `services/`                     |
| **clients**       | GitHub App (JWT, installation token with caching/renewal), Bamboo REST, Slack bot; bounded retries.                                           | `clients/`                      |
| **jobs**          | PostgreSQL queue (`run_at`, named/numeric queues, 5 attempts, 5 min lock); worker; per-PR locks.                   | `jobs/`                         |
| **models**        | SQLAlchemy models over the schema (including the `jobs` and `webhook_deliveries` tables).                                                | `models.py`, `migrations/`      |
| **cli**           | `worker`, `watch-dog`, `pr-bamboo-sync`, `single-sync`, `migrate`, `check-config`, organizations/users console.                               | `cli/main.py`                   |
| **observability** | Logs with secret redaction, Prometheus metrics (multiprocess), `/healthz`, `/readyz`.                                                         | `logs.py`, `metrics.py`         |

## Main flows

### Pull Request webhook → Bamboo execution

```mermaid
sequenceDiagram
    autonumber
    participant GH as GitHub
    participant WEB as web
    participant DB as PostgreSQL
    participant W as worker
    participant B as Bamboo
    participant SL as Slack
    GH->>WEB: pull_request (opened/synchronize/reopened) + X-Hub-Signature-256
    WEB->>WEB: HMAC-SHA256 over the raw body (constant time)
    WEB->>DB: PullRequest, repository plans, GithubUser
    WEB->>DB: job create_execution_by_plan (+5 s, 1 attempt)
    WEB-->>GH: 200 Scheduled Plan Runs
    W->>DB: reserves the job (SKIP LOCKED) + PR advisory lock
    W->>DB: CheckSuite, then cancel the previous execution (jobs, stages, StopPlan)
    W->>B: POST queue/<plan> (customRevision, github_*, signature_secret)
    B-->>W: buildResultKey
    W->>B: comment on the result
    W->>SL: execution started
    W->>B: result/<key>?expand=stages.stage.results
    W->>GH: SkipOldTests + Check Run per stage (queued)
    W->>DB: Stage, CiJob, job timeout_execution (+30 min)
```

### Bamboo status callback and consolidation

```mermaid
flowchart TD
    A([Bamboo: POST /update/status]) --> B{Valid HMAC?}
    B -- no --> X[404 no signature / 401 invalid]
    B -- yes --> C{status == finished?}
    C -- yes --> F[Finished: reconciles with Bamboo]
    C -- no --> D[UpdateStatus]
    D --> E{CiJob exists?}
    E -- no --> E404[404 CI JOB not found]
    E -- yes --> G{valid transition?}
    G -- "queued without in_progress<br/>or in_progress without success/failure" --> G304[304 Not Modified]
    G -- yes --> H[updates CiJob + audit]
    H --> I{current PR execution?}
    I -- yes --> J["debounce: replaces ci_job_status job<br/>(queue = github_pr_id % 10, +30 s)"]
    I -- no --> OK[200 Success]
    J --> OK
    J -.-> S[worker: Summary updates the stage Check Run<br/>and calls Finished when the job has finished]
```

### Reconciliation (`Finished`), timeout and WatchDog

```mermaid
flowchart TD
    A([Finished]) --> B{CheckSuite exists?}
    B -- no --> X[404]
    B -- yes --> C[GET result + result/status on Bamboo]
    C -- unavailable --> U[503, nothing is changed]
    C --> D{still running and not hanged?}
    D -- yes --> S[200 Still running]
    D -- no --> E[check_stages: open jobs get Successful/Failed/Unknown<br/>WatchDog agent + Slack]
    E --> F[clear_deleted_jobs: remaining → skipped]
    F --> G[update_all_stages: Summary from the last stage]
    G --> H[200 Finished]
    T([timeout_execution +30 min]) --> T1{suite finished?}
    T1 -- yes --> T9([end])
    T1 -- no --> T2{no update for > 2 h?}
    T2 -- yes --> T3[metric ci_job_timeout_total + Finished hanged=true]
    T2 -- no --> T4[reschedules +30 min]
    W([watch-dog timer]) --> W1[suites with queued/in_progress stages] --> A
```

### `ci:retry` × `ci:rerun`

```mermaid
flowchart TD
    subgraph RETRY["Partial retry (same CheckSuite)"]
      R0([ci:retry or check_run rerequested]) --> R1{stage found?}
      R1 -- no --> R404[404 Stage not found]
      R1 -- yes --> R2{stage queued/in_progress?}
      R2 -- yes --> R406[406 Already enqueued]
      R2 -- no --> R3{suite still running?}
      R3 -- yes --> R4[406 + Slack; stage goes back to failure]
      R3 -- no --> R5[retry += 1, partial AuditRetry,<br/>re-enqueues non-green stages/jobs,<br/>StopPlan + restart on Bamboo]
    end
    subgraph RERUN["Full rerun (new CheckSuite)"]
      U0([ci:rerun or check_suite rerequested]) --> U1[job per plan, +1 s, 1 attempt]
      U1 --> U2[stops the previous execution<br/>new CheckSuite + Bamboo plan]
      U2 --> U3[full AuditRetry + Action rerun=true<br/>jobs missing from the plan → skipped]
    end
```

## Directory structure

```
netdef-ci-github-app-python/
├── README.md  AGENTS.md  PLAN.md  Makefile
├── requirements.txt  requirements-dev.txt        # pinned dependencies
├── .env.example  github_apps.example.toml        # dummy configuration
├── alembic.ini  migrations/versions/             # 0001 initial schema, 0002 jobs and webhook tables
├── src/netdef_ci/
│   ├── config.py  db.py  models.py  enums.py  security.py  logs.py  metrics.py  container.py
│   ├── web/{app.py,webhooks.py}
│   ├── clients/{github.py,bamboo.py,slack.py,http.py}
│   ├── jobs/{queue.py,handlers.py,registry.py,locks.py}
│   ├── services/{build_plan,update_status,summary,finished,executions,rerun,retry,tasks,...}.py
│   └── cli/main.py
├── tests/{unit,integration,fakes.py,factories.py,payloads.py}
├── scripts/{smoke_test.py,test-with-podman.sh,freeze_requirements.sh,Containerfile.dev}
├── deploy/ansible/{ansible.cfg,inventories/{dev,prod},playbooks,roles/{python_runtime,netdef_ci}}
└── doc/
```

## Python version and dependencies

Python **3.15.2** (details and rationale in `03-technical-decisions.md`). Direct dependencies: FastAPI, uvicorn,
SQLAlchemy, Alembic, psycopg, httpx, PyJWT (+cryptography), pydantic-settings, prometheus-client — all pinned in
`requirements.txt` along with the transitive ones.
