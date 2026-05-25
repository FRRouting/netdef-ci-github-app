# NetDEF CI GitHub App — Technical Documentation

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Technology Stack](#3-technology-stack)
4. [Database Schema](#4-database-schema)
5. [Core Components](#5-core-components)
   - 5.1 [Web Server — GithubApp (Sinatra)](#51-web-server--githubapp-sinatra)
   - 5.2 [GitHub Integration Layer](#52-github-integration-layer)
   - 5.3 [Bamboo CI Integration Layer](#53-bamboo-ci-integration-layer)
   - 5.4 [Models Layer](#54-models-layer)
   - 5.5 [Background Workers (Delayed::Job)](#55-background-workers-delayedjob)
   - 5.6 [Cron / Standalone Scripts](#56-cron--standalone-scripts)
   - 5.7 [Slack Integration](#57-slack-integration)
   - 5.8 [Helpers](#58-helpers)
6. [Key Workflows](#6-key-workflows)
   - 6.1 [New Pull Request / Push to PR](#61-new-pull-request--push-to-pr)
   - 6.2 [Job Status Update from Bamboo](#62-job-status-update-from-bamboo)
   - 6.3 [Plan Execution Finished](#63-plan-execution-finished)
   - 6.4 [Partial Retry (ci:retry / re-request check_run)](#64-partial-retry-ciretry--re-request-check_run)
   - 6.5 [Full Re-Run (ci:rerun / re-request check_suite)](#65-full-re-run-cirerun--re-request-check_suite)
   - 6.6 [Timeout Watchdog](#66-timeout-watchdog)
   - 6.7 [Stuck Jobs Watchdog](#67-stuck-jobs-watchdog)
7. [Authentication & Security](#7-authentication--security)
8. [Configuration](#8-configuration)
9. [Logging](#9-logging)
10. [Deployment](#10-deployment)
11. [Component Dependency Map](#11-component-dependency-map)

---

## 1. Project Overview

The **NetDEF CI GitHub App** is a Sinatra-based Ruby web service that acts as a bridge between GitHub and Atlassian Bamboo CI. It is installed as a GitHub App on one or more repositories and performs the following responsibilities:

- **Receives GitHub webhook events** (pull requests, check runs, check suites, issue comments) and triggers corresponding Bamboo CI plan executions.
- **Receives build status callbacks from Bamboo** via a dedicated HTTP endpoint and reflects those statuses back to GitHub's Checks API in real time.
- **Manages the full CI lifecycle**: queuing, in-progress, success, failure, cancellation, retry, re-run.
- **Sends Slack notifications** to subscribed users about execution start, finish, and individual job/stage outcomes.
- **Handles stuck or timed-out CI jobs** through a combination of scheduled Delayed::Job workers and standalone cron scripts.
- **Maintains an audit trail** of every status transition for every CI job and stage.

The service runs on port **4667**, binds to `0.0.0.0`, and is backed by a **PostgreSQL** database managed through ActiveRecord (via the `otr-activerecord` gem, which provides Rails-style ActiveRecord without requiring the full Rails framework).

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          GITHUB                                     │
│  Pull Request events ──► Webhooks ──► POST /*                       │
│  Check Run re-requests ─────────────► POST /*                       │
│  Issue comments (ci:retry, ci:rerun)► POST /*                       │
│  ◄── Check Runs API (status updates, comments)                      │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ HMAC-SHA256 authenticated webhooks
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│               GithubApp (Sinatra, port 4667)                        │
│                                                                     │
│  POST /*              → GitHub event dispatcher                     │
│  POST /update/status  → Bamboo callback handler                     │
│  POST /slack          → Slack command handler                       │
│  GET  /ping           → Health check                                │
│  GET  /telemetry      → Metrics JSON                                │
└──────┬───────────────────────────────────────────────┬──────────────┘
       │                                               │
       ▼                                               ▼
┌──────────────┐                           ┌─────────────────────┐
│  PostgreSQL  │ ◄─── ActiveRecord ────►   │   Delayed::Job      │
│  Database    │                           │   Workers (queues)  │
└──────────────┘                           └──────────┬──────────┘
                                                      │
                               ┌──────────────────────┼──────────────────────┐
                               ▼                      ▼                      ▼
                    ┌────────────────┐   ┌─────────────────┐   ┌────────────────────┐
                    │  Bamboo CI     │   │  GitHub Checks  │   │  Slack API         │
                    │  (localhost    │   │  API (Octokit)  │   │  (SlackBot)        │
                    │   reverse      │   └─────────────────┘   └────────────────────┘
                    │   proxy)       │
                    └────────────────┘
```

**Communication flows:**

| Direction | Protocol | Authentication |
|---|---|---|
| GitHub → App | HTTPS POST (webhook) | HMAC-SHA256 signature (`X-Hub-Signature-256`) |
| App → GitHub | HTTPS (Octokit) | GitHub App JWT + Installation Token |
| Bamboo → App | HTTP POST (callback) | Basic Auth (netrc) |
| App → Bamboo | HTTPS (Net::HTTP) | Basic Auth (netrc) |
| Slack → App | HTTP POST | Basic Auth (netrc) |
| App → Slack | HTTPS | Slack Bot Token |

---

## 3. Technology Stack

| Component | Technology |
|---|---|
| Runtime | Ruby >= 3.1.2 |
| Web Framework | Sinatra |
| Application Server | Puma |
| Database | PostgreSQL |
| ORM | ActiveRecord via `otr-activerecord` |
| Background Jobs | `delayed_job_active_record` |
| GitHub API Client | Octokit |
| Authentication | JWT (GitHub App), HMAC-SHA256 (webhooks), netrc (Bamboo/Slack) |
| HTTP Client | `Net::HTTP` with `faraday-retry` |
| Logging | Ruby `Logger` (file-based, rolling) |
| Testing | RSpec, FactoryBot, WebMock, DatabaseCleaner, SimpleCov |
| Linting | RuboCop |

---

## 4. Database Schema

### Entity-Relationship Overview

```
Organization
    └── has_many: GithubUser

GithubUser
    ├── has_many: PullRequest
    ├── has_many: CheckSuite
    └── has_many: AuditRetry

PullRequest
    ├── has_and_belongs_to_many: Plan
    └── has_many: CheckSuite
           ├── belongs_to: Plan
           ├── belongs_to (optional): stopped_in_stage → Stage
           ├── belongs_to (optional): cancelled_previous_check_suite → CheckSuite
           ├── has_many: Stage
           │       ├── belongs_to: StageConfiguration
           │       ├── has_many: CiJob
           │       └── has_many (poly): AuditStatus
           ├── has_many: CiJob
           │       ├── has_many: TopotestFailure
           │       ├── has_many (poly): AuditStatus
           │       └── has_and_belongs_to_many: AuditRetry
           └── has_many: AuditRetry
```

### Table Descriptions

#### `pull_requests`
Represents a GitHub Pull Request. Created when a PR is opened and persisted across all subsequent pushes.

| Column | Type | Description |
|---|---|---|
| `github_pr_id` | integer | GitHub PR number |
| `author` | string | GitHub login of PR author |
| `branch_name` | string | Head branch name |
| `repository` | string | Full repo name (`org/repo`) |

#### `check_suites`
Represents a single CI execution run. A new `CheckSuite` is created for every push to a PR branch and for every re-run.

| Column | Type | Description |
|---|---|---|
| `commit_sha_ref` | string | The merge commit SHA sent to Bamboo |
| `base_sha_ref` | string | Base branch SHA at the time of submission |
| `bamboo_ci_ref` | string | Bamboo build result key (e.g., `PROJ-PLAN-123`) |
| `merge_branch` | string | The temporary merge branch created for the build |
| `re_run` | boolean | Whether this suite was triggered by a re-run command |
| `retry` | integer | How many partial retries have been performed |
| `sync` | boolean | Internal synchronization flag |
| `stopped_in_stage_id` | bigint | FK to the stage where a previous execution was stopped |
| `cancelled_previous_check_suite_id` | bigint | Self-referential FK to the cancelled predecessor |

#### `stages`
Groups CI jobs into a named stage matching Bamboo's stage concept. Each `CheckSuite` has one `Stage` per configured `StageConfiguration`.

| Column | Type | Description |
|---|---|---|
| `name` | string | Display name: `"<github_check_run_name> - <plan_name>"` |
| `status` | enum | `queued / in_progress / success / cancelled / failure / skipped` |
| `check_ref` | string | GitHub Check Run ID for this stage |
| `execution_time` | integer | Seconds from `in_progress` to terminal state |
| `stage_configuration_id` | bigint | FK to `StageConfiguration` |

#### `ci_jobs`
Represents a single job within a Bamboo stage. The most granular unit tracked.

| Column | Type | Description |
|---|---|---|
| `name` | string | Job display name |
| `status` | enum | `queued / in_progress / success / cancelled / failure / skipped` |
| `job_ref` | string | Bamboo job result key (used to match Bamboo callbacks) |
| `check_ref` | string | GitHub Check Run ID for this job |
| `execution_time` | integer | Execution duration in seconds |
| `summary` | string | Error summary captured from Bamboo (for checkout failures) |
| `retry` | integer | Retry count |

#### `stage_configurations`
Admin-defined mapping between Bamboo stage names and GitHub display names.

| Column | Type | Description |
|---|---|---|
| `bamboo_stage_name` | string | Stage name as reported by Bamboo API |
| `github_check_run_name` | string | Name shown in GitHub's Checks UI |
| `position` | integer | Sequential order of this stage in the pipeline |
| `can_retry?` | boolean | Whether this stage can be retried via `ci:retry` |
| `mandatory?` | boolean | If failed, subsequent stages are cancelled |
| `start_in_progress?` | boolean | Stage transitions to `in_progress` immediately on creation |

#### `audit_statuses`
Polymorphic audit log of every status transition for both `CiJob` and `Stage`.

| Column | Type | Description |
|---|---|---|
| `auditable_type` | string | `"CiJob"` or `"Stage"` |
| `auditable_id` | bigint | FK to the audited record |
| `status` | enum | The new status at the time of the event |
| `agent` | string | Who triggered the change (e.g., `'Github'`, `'WatchDog'`, `'StuckJobsWatchdog'`) |

#### `audit_retries`
Records each manual retry or re-run action initiated by a user.

| Column | Type | Description |
|---|---|---|
| `github_username` | string | GitHub login of the user who triggered the action |
| `retry_type` | string | `'partial'` (ci:retry) or `'full'` (ci:rerun) |
| `check_suite_id` | bigint | The suite being retried |

#### `topotest_failures`
Stores individual test case failures parsed from Bamboo results. Associated with a `CiJob`.

| Column | Type | Description |
|---|---|---|
| `test_suite` | string | Test suite name |
| `test_case` | string | Test case name |
| `message` | string | Failure message or traceback |
| `execution_time` | float | Time taken by this specific test case |

#### `delayed_jobs`
Standard Delayed::Job table. Managed by the `delayed_job_active_record` gem.

| Column | Type | Description |
|---|---|---|
| `handler` | text | YAML-serialized job object |
| `queue` | string | Named queue (e.g., `'timeout_execution'`) |
| `run_at` | datetime | Scheduled execution time |
| `attempts` | integer | Number of execution attempts |
| `last_error` | text | Last failure message |

---

## 5. Core Components

### 5.1 Web Server — GithubApp (Sinatra)

**File:** `app/github_app.rb`

The entry point for all inbound HTTP traffic. Extends `Sinatra::Base`.

#### Routes

| Method | Path | Handler |
|---|---|---|
| `GET` | `/ping` | Returns `200 Pong`. Health check. |
| `GET` | `/telemetry` | Returns JSON with operational metrics from `Telemetry.instance.stats`. |
| `POST` | `/update/status` | Bamboo CI callback. Routes to `Github::PlanExecution::Finished` (when `status == 'finished'`) or `Github::UpdateStatus` (otherwise). Authenticated via HMAC. |
| `POST` | `/slack` | Slack command handler. Routes to `Slack::Running` (event-based) or `Slack::Subscribe`. |
| `POST` | `/slack/settings` | Slack settings handler → `Slack::Settings`. |
| `POST` | `/*` | GitHub webhook catch-all. Dispatches based on `X-Github-Event` header. |

#### GitHub Event Dispatch (`POST /*`)

```
X-Github-Event: pull_request  (action: opened, synchronize, reopened)
    └── Github::BuildPlan.new(payload).create

X-Github-Event: check_run     (action: rerequested)
    └── Github::Retry::Command.new(payload).start

X-Github-Event: check_suite   (action: rerequested)
    └── Github::ReRun::Command.new(payload).start

X-Github-Event: issue_comment
    ├── body matches /ci:retry/  → Github::Retry::Comment.new(payload).start
    └── body matches /ci:rerun/  → Github::ReRun::Comment.new(payload).start

X-Github-Event: installation   → 202 Accepted (no-op)
X-Github-Event: ping           → 200 PONG!
```

All GitHub webhook requests are validated with HMAC-SHA256 (see [Section 7](#7-authentication--security)).

---

### 5.2 GitHub Integration Layer

#### `Github::Check` (`lib/github/check.rb`)

The core GitHub API client. Wraps Octokit and handles GitHub App authentication.

**Authentication flow:**
1. Loads `config.yml` to find the matching GitHub App entry for the target repository.
2. Reads the RSA private key from the path specified in config (`app['cert']`).
3. Generates a JWT (valid for 10 minutes minus 30 seconds of clock skew buffer).
4. Exchanges the JWT for an Installation Access Token via `Octokit::Client#create_app_installation_access_token`.
5. All subsequent API calls use this token.

**Key methods:**

| Method | Description |
|---|---|
| `create(name)` | Creates a new GitHub Check Run in `queued` state. Returns the check run object (`.id` is the `check_ref`). |
| `queued(check_ref, output)` | Updates a check run to `queued` status. |
| `in_progress(check_ref, output)` | Updates a check run to `in_progress` status. |
| `success / failure / cancelled / skipped` | Calls `completed(check_ref, 'completed', conclusion, output)`. |
| `add_comment(pr_id, comment, repo)` | Posts a comment to a PR. |
| `comment_reaction_thumb_up/down` | Adds emoji reaction to a comment. |

**Retry logic on `completed`:** If the GitHub API returns `Octokit::NotFound` or a `RuntimeError` (status mismatch), the call is retried up to 3 times with a linear backoff (`sleep retry_count * 5`).

---

#### `Github::BuildPlan` (`lib/github/build_plan.rb`)

Entry point for `pull_request` events. Handles actions `opened`, `synchronize`, and `reopened`.

1. Finds or creates a `PullRequest` record in the database.
2. Associates all `Plan` records matching the repository with the `PullRequest`.
3. Delegates to `Github::Build::PlanRun.new(pull_request, payload).build` to start the CI pipeline.

---

#### `Github::Build::PlanRun` (`lib/github/build/plan_run.rb`)

Iterates over all `Plan` records associated with the `PullRequest` and schedules an async `CreateExecutionByPlan` worker for each, with a configurable delay (`TIMER` constant).

---

#### `Github::Build::Action` (`lib/github/build/action.rb`)

Creates the database records and GitHub Check Runs for a new CI execution.

1. Calls `Github::Build::SkipOldTests` to mark obsolete jobs from previous runs as skipped.
2. For each `StageConfiguration`, calls `create_check_run_stage` which either creates a new `Stage` record and its GitHub Check Run, or re-enqueues an existing retryable stage.
3. For each job returned by Bamboo (`@jobs`), creates a `CiJob` record linked to the correct `Stage`.
4. Schedules a `TimeoutExecution` Delayed::Job 30 minutes in the future.

---

#### `Github::Build::Summary` (`lib/github/build/summary.rb`)

Called after every job status change to update the stage's GitHub Check Run with a current progress report and manage stage transitions.

**`build_summary` sequence:**

```
1. Resolve current stage (query DB, or fetch from Bamboo if missing)
2. Return early if stage is cancelled
3. update_summary(stage)         → set stage to in_progress with current job list
4. finished_summary(stage)       → if all jobs done, mark stage success or failure
5. must_cancel_next_stages(stage) → if mandatory stage failed, cancel downstream stages
6. must_continue_next_stage(stage) → if stage passed, move next stage to in_progress
7. must_update_previous_stage(stage) → if previous stage is still queued/in_progress, update it
```

The markdown output shown in the GitHub Check Run panel is built by `summary_basic_output`, which composes:
- Queued jobs list
- In-progress jobs list
- Failed / cancelled jobs with test failure details (from `TopotestFailure` records)
- Successful jobs list

Output is truncated at 65,535 characters (GitHub API limit).

---

#### `Github::UpdateStatus` (`lib/github/update_status.rb`)

Handles individual job status callbacks from Bamboo (`POST /update/status` with `status != 'finished'`).

**Flow:**

```
1. Find CiJob by job_ref (bamboo_ref in payload)
2. Guard: if job is queued and status != 'in_progress', return 304 Not Modified
3. Guard: if job is in_progress and status not in [success, failure], return 304
4. Dispatch:
   - 'in_progress' → job.in_progress(github_check)
   - 'success'     → job.success(github_check) + update_execution_time
   - anything else → failure flow (job.failure + store TopotestFailures)
5. If this check_suite is the current execution for its PR:
   → delete old CiJobStatus Delayed::Job for this bamboo_ref
   → schedule new CiJobStatus.delay(...).update(bamboo_ci_ref, job_id)
```

**Queue routing:** `pr_id % 10` — distributes summary update jobs across 10 named queues to avoid serializing all PRs through a single worker.

**Topotest failures:** If the payload contains a `failures` array, records are created immediately. If the array is empty (Bamboo may not have written results yet), a `CiJobFetchTopotestFailures` worker is scheduled with exponential backoff (5, 10, 15, 20 minutes).

---

#### `Github::PlanExecution::Finished` (`lib/github/plan_execution/finished.rb`)

Handles the `status == 'finished'` callback from Bamboo (plan-level completion, not job-level).

**Flow:**

```
1. Find CheckSuite by bamboo_ci_ref
2. Fetch build status from Bamboo API
3. If still in_progress? (progress < 2% and not on 'final' stage) → return 200 'Still running'
4. check_stages → iterate Bamboo result stages/jobs, update each CiJob status
5. clear_deleted_jobs → skip any CiJobs still queued/in_progress (Bamboo removed them)
6. update_all_stages → build_summary for the last stage's last job
7. If PR's current execution is this suite and suite is finished → Slack notification
```

`ci_hanged?`: Returns `true` if progress percentage ≥ 2.0% (Bamboo reports 2% for most "completed" states) or if the build has a `message` key but no `finished` key (stopped/error state).

---

#### `Github::Retry::Base` (`lib/github/retry/base.rb`)

Base class for partial retry operations (re-run only failed jobs within a stage, keeping successful jobs).

**`start` flow:**

```
1. Validate stage exists and is in a failed terminal state
2. If check_suite is in_progress → enqueued() (reject with Slack DM)
3. Otherwise → normal_flow():
   a. Increment check_suite.retry counter
   b. Create AuditRetry record
   c. Github::Build::Retry → re-enqueue failed CiJobs with queued status
   d. BambooCi::Retry.restart → tell Bamboo to restart the failed stage
   e. Github::Build::UnavailableJobs → mark jobs not in this run as skipped
   f. Slack notification
   g. Thumb-up reaction on triggering comment (if applicable)
```

Subclasses:
- `Github::Retry::Command` — triggered by GitHub's "Re-run" button on a check run (`check_run` rerequested event)
- `Github::Retry::Comment` — triggered by `ci:retry` comment; finds the earliest failed stage automatically

---

#### `Github::ReRun::Base` (`lib/github/re_run/base.rb`)

Base class for full re-run operations (start the entire CI pipeline from scratch).

**`start_new_execution` flow:**

```
1. stop_previous_execution(plan):
   - Find all check_suites with in_progress jobs for this PR+plan
   - For each: record stopped_in_stage, cancel all jobs, call BambooCi::StopPlan
2. Create new CheckSuite record
3. BambooCi::PlanRun.start_plan → submit PR to Bamboo, get bamboo_ci_ref
4. ci_jobs(check_suite, plan):
   a. Slack: execution_started_notification
   b. Fetch running jobs from Bamboo
   c. Github::Build::Action.create_summary(rerun: true)
   d. Update unavailable jobs
```

Subclasses:
- `Github::ReRun::Command` — triggered by GitHub's "Re-run all checks" on a check suite
- `Github::ReRun::Comment` — triggered by `ci:rerun` (optionally with a specific commit SHA: `ci:rerun #abc1234`)

---

### 5.3 Bamboo CI Integration Layer

All Bamboo API calls use the `BambooCi::Api` mixin (`lib/bamboo_ci/api.rb`), which in turn uses `GitHubApp::Request`. All requests go to `https://127.0.0.1` — Bamboo is accessed via a local reverse proxy.

#### `BambooCi::PlanRun`
Submits a PR to Bamboo. Constructs the queue URL with custom variables:

| Variable | Value |
|---|---|
| `customRevision` | `merge_branch` |
| `github_repo` | Repository full name (URL-encoded) |
| `github_pullreq` | PR number |
| `github_branch` | Merge branch |
| `github_merge_sha` | Commit SHA of the merge commit |
| `github_base_sha` | Base branch SHA |

Also passes `github_signature_secret` for Bamboo-side HMAC validation of callbacks.

Returns the `bamboo_ci_ref` (build result key, e.g., `MYPROJ-CI-42`) extracted from the Bamboo API response.

#### `BambooCi::RunningPlan`
Fetches the list of jobs currently in the running plan. Returns an array of hashes with `:name`, `:job_ref`, and `:stage` keys. Used to populate `CiJob` records when a plan starts.

#### `BambooCi::Result`
Fetches the detailed result of a completed job, including test results and artifact links. Used by `Summary#build_message` to retrieve build error logs.

#### `BambooCi::StopPlan`
Sends a DELETE request to Bamboo to stop a running plan. Called when cancelling a previous execution before starting a re-run.

#### `BambooCi::Retry`
Sends a PUT request to Bamboo to restart a failed stage. Used during partial retry (`ci:retry`).

#### `BambooCi::Download`
Downloads artifact content (e.g., build error logs) from Bamboo's artifact storage URL.

---

### 5.4 Models Layer

All models use ActiveRecord enums for `status` with consistent values:

```ruby
enum status: { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }
```

#### `CiJob` (`lib/models/ci_job.rb`)

The most active model. Each status transition method follows the same pattern:

```ruby
def failure(github, output: {}, agent: 'Github')
  unless check_ref.nil?
    create_github_check(github)   # creates GitHub Check Run if not yet created
    github.failure(check_ref, output)  # updates GitHub Check Run status
  end
  AuditStatus.create(auditable: self, status: :failure, agent: agent, created_at: Time.now)
  update(status: :failure)
end
```

`create_github_check` (private) creates a GitHub Check Run via `github.create(name)` only if `check_ref` is nil, then stores the returned ID.

`update_execution_time`: Calculates duration from the first `in_progress` to the first `success/failure` audit status entry.

#### `Stage` (`lib/models/stage.rb`)

Similar status transition methods to `CiJob`, with additional stage-level concerns:

- `previous_stage`: Finds the stage at `position - 1` in the same check suite with the same name suffix.
- `running?`: Returns `true` if any child `CiJob` is `queued` or `in_progress`.
- `finished?`: Returns `true` if no child `CiJob` is `queued` or `in_progress`.
- `in_progress_notification` / `notification`: Triggers Slack alerts on state change.
- `refresh_reference(github)`: Always creates a new GitHub Check Run (used before terminal state updates).

#### `CheckSuite` (`lib/models/check_suite.rb`)

| Method | Description |
|---|---|
| `running?` | True if any Stage is `queued` or `in_progress`. |
| `finished?` | Inverse of `running?`. |
| `running_jobs` | Returns CiJobs with `queued` or `in_progress` status. |
| `stages_failure` | Returns stages that have at least one failed or cancelled job. |
| `last_job_updated_at_timer` | Returns the `updated_at` of the most recently updated CiJob (used by timeout logic). |

#### `PullRequest` (`lib/models/pull_request.rb`)

- `current_execution?(check_suite)`: Returns `true` if the given suite is the most recently created suite for this PR and plan. Used to skip notifications for superseded executions.
- `current_execution_by_plan(plan)`: Returns the latest `CheckSuite` for a given plan.

---

### 5.5 Background Workers (Delayed::Job)

Workers are plain Ruby classes with class-level methods invoked via `.delay(...)`. They are not ActiveJob-style classes.

#### `CiJobStatus` (`workers/ci_job_status.rb`)
Scheduled after every job status update. Builds the stage summary and checks if the overall execution has finished. Runs in a numbered queue (`pr_id % 10`) to distribute load.

#### `CiJobFetchTopotestFailures` (`workers/ci_job_fetch_topotest_failures.rb`)
Fetches topotest failure details from Bamboo with exponential backoff. Retries up to 3 times (at 5, 10, 15-minute intervals). If failures are found, creates `TopotestFailure` records. If not found after 3 retries, gives up.

#### `CreateExecutionByPlan` (`workers/create_execution_by_plan.rb`)
The main async worker for initiating a new CI run from a PR event. Handles:
- Stopping the previous execution for the same plan
- Creating the `CheckSuite` record
- Submitting the plan to Bamboo
- Creating stages and jobs
- Scheduling the timeout worker

#### `CreateExecutionByComment` (`workers/create_execution_by_comment.rb`)
Handles `ci:rerun #SHA` or `ci:rerun` commands from PR comments. Finds the target commit SHA (specified or latest) and starts a new execution.

#### `CreateExecutionByCommand` (`workers/create_execution_by_command.rb`)
Handles the GitHub UI "Re-run all checks" action on a check suite.

#### `TimeoutExecution` (`workers/timeout_execution.rb`)
Scheduled 30 minutes after every new CI execution. Checks if the `CheckSuite` has finished:
- **Finished** → exits (no-op)
- **Last job updated > 2 hours ago** → calls `watchdog` to mark stuck jobs as failure
- **Otherwise** → reschedules itself 30 minutes into the future

`watchdog`: Marks each `CiJob` with `updated_at < 2.hours.ago` and status `in_progress/queued` as failure, and calls `Github::Build::Summary`.

---

### 5.6 Cron / Standalone Scripts

These are standalone Ruby scripts intended to be run via OS cron. They `require_relative` the setup file and instantiate a class directly.

#### `workers/watch_dog.rb`
Finds all `CheckSuite` records with stages in `queued` or `in_progress` state and calls `Github::PlanExecution::Finished` for each, forcing a status sync with Bamboo.

**Shell script:** `bin/watch_dog_prod.sh`

#### `workers/stuck_jobs_watchdog.rb`
Targets `CiJob` records stuck in `in_progress` state for between 2 and 24 hours. For each:
1. Creates a `Github::Check` for the job's check suite
2. Calls `job.failure(github, agent: 'StuckJobsWatchdog')`
3. Calls `Github::Build::Summary.new(job).build_summary`

**Shell script:** `bin/stuck_jobs_watchdog_prod.sh`

**Recommended cron entry:**
```cron
0 * * * * /home/githubchecks/server/bin/stuck_jobs_watchdog_prod.sh
```

---

### 5.7 Slack Integration

#### `SlackBot` (`lib/slack_bot/slack_bot.rb`)
Singleton class. Sends Slack messages for:

| Event | Method |
|---|---|
| CI execution starts | `execution_started_notification(check_suite)` |
| CI execution finishes | `execution_finished_notification(check_suite)` |
| Stage transitions to in_progress | `stage_in_progress_notification(stage)` |
| Stage finishes | `stage_finished_notification(stage)` |
| Individual job success | `notify_success(job)` |
| Individual job failure | `notify_errors(job)` |
| Individual job cancelled | `notify_cancelled(job)` |
| Invalid retry while running | `invalid_rerun_group(stage)` + `invalid_rerun_dm(stage, subscription)` |

Notifications are sent to users who have subscribed via `PullRequestSubscription` (targeting a PR number or author login, with a notification level of `all` or `errors`).

#### Slack Commands (`lib/slack/`)
- `Slack::Subscribe` — handles PR subscription management commands
- `Slack::Running` — handles event-based Slack messages (mentions, etc.)
- `Slack::Settings` — handles user settings changes

---

### 5.8 Helpers

#### `GitHubApp::Configuration` (`lib/helpers/configuration.rb`)
Singleton. Reads `config.yml` from the project root. Provides:
- `config` — the full parsed YAML hash
- `ci_url` — Bamboo CI base URL (falls back to `https://ci1.netdef.org`)
- `debug?` — enables `Logger::DEBUG` level logging
- `reload` — re-reads the file (called on each request to pick up config changes)

#### `GithubLogger` (`lib/helpers/github_logger.rb`)
Singleton factory for file-based loggers. Creates rotating log files under `./logs/`. Each file rolls at 500 MB, keeping 2 files. Multiple classes share logger instances for the same filename.

#### `GitHubApp::Request` (`lib/helpers/request.rb`)
Module mixin providing `get_request`, `post_request`, `put_request`, `delete_request`, and `download`. All methods use `Net::HTTP` with Basic Auth from netrc. Credentials are loaded by machine name (defaulting to `ci1.netdef.org`).

#### `Sinatra::Payload` (`lib/helpers/sinatra_payload.rb`)
Sinatra helper module. Provides `authenticate_request`, which validates the `X-Hub-Signature-256` header using HMAC-SHA256 with the secret from `config.yml`.

#### `Telemetry` (`lib/helpers/telemetry.rb`)
Singleton. Reads/writes a `telemetry.json` file with operational counters exposed via `GET /telemetry`.

---

## 6. Key Workflows

### 6.1 New Pull Request / Push to PR

```
GitHub sends 'pull_request' event (opened / synchronize / reopened)
    │
    ▼
GithubApp#POST /*
    │
    ▼
Github::BuildPlan#create
    ├── Find or create PullRequest record
    ├── Associate Plans (by repository name)
    └── Github::Build::PlanRun#build
            │
            └── For each Plan:
                    CreateExecutionByPlan
                      .delay(run_at: TIMER.seconds.from_now, queue: 'create_execution_by_plan')
                      .build(pull_request_id, plan_id, payload)
                            │
                            ▼
                    [Async Worker]
                    1. Stop previous execution (cancel jobs, stop Bamboo plan)
                    2. Create CheckSuite record
                    3. BambooCi::PlanRun → submit to Bamboo → get bamboo_ci_ref
                    4. BambooCi::RunningPlan → fetch job list
                    5. Github::Build::Action#create_summary
                       ├── Create Stage records + GitHub Check Runs (queued)
                       ├── Create CiJob records
                       └── Schedule TimeoutExecution (30 min)
                    6. Slack: execution_started_notification
```

---

### 6.2 Job Status Update from Bamboo

```
Bamboo sends POST /update/status { bamboo_ref, status, failures? }
    │
    ▼
GithubApp handles /update/status
    │
    ▼
Github::UpdateStatus#update
    ├── Find CiJob by job_ref
    ├── Apply status guards (304 if no-op)
    ├── Update CiJob status (in_progress / success / failure)
    │   └── If failure and failures[] not empty → create TopotestFailure records
    │   └── If failure and failures[] empty → schedule CiJobFetchTopotestFailures
    └── Schedule CiJobStatus.delay(...).update(bamboo_ci_ref, job_id)
            │
            ▼
    [Async Worker — CiJobStatus]
    Github::Build::Summary#build_summary
        ├── Update stage in_progress with job progress markdown
        ├── If stage finished → mark stage success or failure
        ├── If mandatory stage failed → cancel downstream stages
        └── If stage passed → move next stage to in_progress
```

---

### 6.3 Plan Execution Finished

```
Bamboo sends POST /update/status { bamboo_ref, status: 'finished' }
    │
    ▼
Github::PlanExecution::Finished#finished
    ├── Fetch build status from Bamboo API
    ├── If still running (progress < 2%) → return 200 'Still running'
    ├── check_stages → for each Bamboo job result:
    │       Find CiJob, update status (Unknown→cancelled, Failed→failure, Successful→success)
    │       build_summary for each updated job
    ├── clear_deleted_jobs → skip any CiJobs still queued/in_progress
    ├── update_all_stages → build_summary for last stage's last job
    └── If suite finished and is current execution → Slack: execution_finished_notification
```

---

### 6.4 Partial Retry (ci:retry / re-request check_run)

```
Trigger: PR comment "ci:retry" or GitHub "Re-run" button on a check run
    │
    ▼
Github::Retry::Comment or Github::Retry::Command
    │  (finds the target Stage)
    ▼
Github::Retry::Base#start
    ├── Guard: stage not found → 404
    ├── Guard: stage still queued/in_progress → 406
    ├── If check_suite in_progress → enqueued() (reject, Slack DM)
    └── normal_flow():
        ├── Increment check_suite.retry
        ├── AuditRetry.create (retry_type: 'partial')
        ├── Github::Build::Retry → re-enqueue failed CiJobs as queued
        ├── BambooCi::Retry.restart → restart failed Bamboo stage
        ├── Github::Build::UnavailableJobs → mark missing jobs as skipped
        ├── Slack: execution_started_notification
        └── Comment reaction 👍 (if triggered by comment)
```

---

### 6.5 Full Re-Run (ci:rerun / re-request check_suite)

```
Trigger: PR comment "ci:rerun [#SHA]" or GitHub "Re-run all checks" on check suite
    │
    ▼
Github::ReRun::Comment or Github::ReRun::Command
    │
    ▼
Github::ReRun::Base
    ├── stop_previous_execution(plan):
    │   ├── Find check_suites with in_progress jobs
    │   └── For each: record stopped_in_stage, cancel all jobs, BambooCi::StopPlan
    ├── Create new CheckSuite record
    ├── start_new_execution(check_suite, plan):
    │   ├── BambooCi::PlanRun.start_plan → get bamboo_ci_ref
    │   └── AuditRetry.create (retry_type: 'full')
    └── ci_jobs(check_suite, plan):
        ├── Slack: execution_started_notification
        ├── BambooCi::RunningPlan → fetch jobs
        ├── Github::Build::Action#create_summary(rerun: true)
        └── Github::Build::UnavailableJobs → mark unavailable jobs
```

---

### 6.6 Timeout Watchdog

```
[Scheduled by Github::Build::Action, 30 min after execution start]

TimeoutExecution#timeout(check_suite_id)
    ├── If check_suite.finished? → exit (no-op)
    ├── If last_job_updated_at < 2.hours.ago → watchdog(check_suite):
    │       For each CiJob in [queued, in_progress] with updated_at < 2h ago:
    │           job.failure(github, agent: 'TimeoutExecution')
    │           Github::Build::Summary.new(job).build_summary
    └── Otherwise → rescheduling(check_suite_id):
            TimeoutExecution.delay(run_at: 30.min.from_now).timeout(check_suite_id)
```

---

### 6.7 Stuck Jobs Watchdog

```
[Cron job — runs independently of Delayed::Job]

StuckJobsWatchdog#perform
    ├── Query: CiJob.in_progress.where(updated_at: 24.hours.ago..2.hours.ago)
    └── For each stuck job:
        ├── Github::Check.new(job.check_suite)
        ├── job.failure(github, agent: 'StuckJobsWatchdog')
        └── Github::Build::Summary.new(job).build_summary
```

This watchdog acts as a safety net for jobs that the `TimeoutExecution` worker may have missed — for example, if the worker itself crashed or if the job was created outside the normal flow.

---

## 7. Authentication & Security

### GitHub Webhook Validation

Every `POST /*` and `POST /update/status` request is validated in `Sinatra::Payload#authenticate_request`:

```ruby
expected = "sha256=#{OpenSSL::HMAC.hexdigest('sha256', secret, raw_body)}"
halt 401 unless Rack::Utils.secure_compare(expected, request.env['HTTP_X_HUB_SIGNATURE_256'])
```

The secret is read from `config.yml` (`auth_signature.password`).

### GitHub App Authentication

Each `Github::Check` instance authenticates independently:
1. Generates a JWT signed with the app's RSA private key (path in `config.yml`).
2. Fetches an Installation Access Token via GitHub's API.
3. Tokens expire after 10 minutes; a new token is obtained per `Github::Check` instantiation.

### Bamboo / Slack Authentication

Credentials are stored in `~/.netrc`, keyed by machine name. Loaded via the `netrc` gem:

```ruby
user, passwd = Netrc.read['ci1.netdef.org']
req.basic_auth user, passwd
```

Slack requests are authenticated by comparing the `Authorization` header against the expected Basic Auth value for `slack_bot.netdef.org`.

---

## 8. Configuration

**File:** `config/config.yml` (not tracked in VCS)

Expected structure:

```yaml
debug: false

ci:
  url: ci1.netdef.org     # Bamboo hostname (no https://)

auth_signature:
  password: "your-github-webhook-secret"

github_apps:
  - login: "123456"        # GitHub App installation ID
    cert: "/path/to/private-key.pem"
    repo: "org/specific-repo"   # optional: repo-specific app

  - login: "789012"        # Fallback app (no 'repo' key)
    cert: "/path/to/other-key.pem"
```

The app supports multiple GitHub App configurations. When handling a request, it first tries to find an app entry whose `repo` matches the target repository. If none is found or the `check_suite` is nil, it falls back to the first app without a `repo` key.

**Database:** `config/database.yml` — standard ActiveRecord YAML config. Uses a pool of 10 connections per environment.

**Delayed::Job:** `config/delayed_job.rb` — configures worker count and queue names.

---

## 9. Logging

All logs are written to `./logs/` using rotating file loggers (`GithubLogger`).

| Log File | Written by | Content |
|---|---|---|
| `github_app.log` | `GithubApp`, `BuildAction`, `Summary`, `ReRun::Base`, `Retry::Base` | General request/event processing |
| `github_check_api.log` | `Github::Check` | Every GitHub API call and response |
| `github_build_summary.log` | `Github::Build::Summary` | Stage transition decisions |
| `github_build_action.log` | `Github::Build::Action` | Job and stage creation |
| `github_update_status.log` | `Github::UpdateStatus` | Bamboo → GitHub status updates |
| `github_plan_execution_finished.log` | `Github::PlanExecution::Finished` | Plan completion handling |
| `github_retry.log` | `Github::Retry::Base` | Retry operations |
| `timeout_execution_worker.log` | `TimeoutExecution` | Timeout watchdog activity |
| `stuck_jobs_watchdog.log` | `StuckJobsWatchdog` | Stuck job detection and resolution |
| `pr<ID>.log` | `BuildAction`, `Summary`, `UpdateStatus` | Per-PR log aggregating all events for that PR |
| `stdout` | `UpdateStatus`, `GithubApp` | Mirror of key events for systemd/journald capture |

Log level is `INFO` by default. Set `debug: true` in `config.yml` to enable `DEBUG` level for incoming webhook payloads.

---

## 10. Deployment

### Process Structure

The application runs as two separate process groups:

**1. Web Server (Puma)**
```bash
RACK_ENV=production bundle exec puma -C config/puma.rb
```
Handles all inbound HTTP traffic on port 4667.

**2. Delayed::Job Workers**
```bash
RACK_ENV=production bundle exec rake jobs:work
```
Processes the async job queues. Multiple workers can run in parallel; each worker picks up jobs from any queue.

### Cron Jobs

```cron
# Watch Dog — sync check suites with Bamboo (adjust frequency as needed)
*/15 * * * * /home/githubchecks/server/bin/watch_dog_prod.sh

# Stuck Jobs Watchdog — clean up jobs stuck > 2 hours
0 * * * * /home/githubchecks/server/bin/stuck_jobs_watchdog_prod.sh
```

### Directory Structure

```
netdef-ci-github-app/
├── app/
│   └── github_app.rb          # Sinatra application
├── bin/
│   ├── watch_dog_prod.sh
│   └── stuck_jobs_watchdog_prod.sh
├── config/
│   ├── setup.rb               # Loads all dependencies
│   ├── database.yml
│   ├── puma.rb
│   ├── delayed_job.rb
│   └── config.yml             # ← not in VCS, must be created manually
├── db/
│   ├── schema.rb
│   └── migrate/
├── lib/
│   ├── bamboo_ci/             # Bamboo API client modules
│   ├── github/                # GitHub integration classes
│   ├── helpers/               # Configuration, logging, HTTP, auth
│   ├── models/                # ActiveRecord models
│   └── slack*/                # Slack bot and command handlers
├── workers/
│   ├── ci_job_status.rb
│   ├── ci_job_fetch_topotest_failures.rb
│   ├── create_execution_by_plan.rb
│   ├── create_execution_by_comment.rb
│   ├── create_execution_by_command.rb
│   ├── timeout_execution.rb
│   ├── stuck_jobs_watchdog.rb
│   └── watch_dog.rb
└── spec/                      # RSpec test suite
```

---

## 11. Component Dependency Map

```
GithubApp (Sinatra)
├── Github::BuildPlan
│   └── Github::Build::PlanRun
│       └── [Delayed::Job] CreateExecutionByPlan
│           ├── BambooCi::StopPlan
│           ├── BambooCi::PlanRun
│           ├── BambooCi::RunningPlan
│           └── Github::Build::Action
│               ├── Github::Build::SkipOldTests
│               ├── Github::Check
│               └── [Delayed::Job] TimeoutExecution
│                   └── Github::Build::Summary
│                       ├── Github::Check
│                       └── BambooCi::Result / Download
│
├── Github::UpdateStatus
│   ├── Github::Check
│   ├── [Delayed::Job] CiJobStatus
│   │   └── Github::Build::Summary
│   └── [Delayed::Job] CiJobFetchTopotestFailures
│
├── Github::PlanExecution::Finished
│   ├── BambooCi::Api (get_status)
│   ├── Github::Check
│   └── Github::Build::Summary
│
├── Github::Retry::Base (← Command / Comment)
│   ├── Github::Check
│   ├── Github::Build::Retry
│   ├── BambooCi::Retry
│   └── Github::Build::UnavailableJobs
│
└── Github::ReRun::Base (← Command / Comment)
    ├── BambooCi::StopPlan
    ├── BambooCi::PlanRun
    ├── Github::Build::Action
    └── Github::Build::UnavailableJobs

[Cron] WatchDog
└── Github::PlanExecution::Finished

[Cron] StuckJobsWatchdog
├── Github::Check
└── Github::Build::Summary
```
