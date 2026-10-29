# 12 — Adding a plan (repository ↔ Bamboo plan)

A **plan** is one row of the `plans` table. It tells the app which Bamboo plan to start when a pull request of a given
GitHub repository is opened, pushed to or reopened. There is no console command or endpoint to manage plans: rows are
inserted with SQL. Without at least one plan the pull request webhook answers `422 No Plans associated with this Pull
Request` and nothing runs (there is no default plan).

## How a plan is used

1. GitHub sends `pull_request` (`opened`, `synchronize`, `reopened`) to the webhook.
2. `services/build_plan.py` selects every row with `plans.github_repo_name = <repository.full_name>` (ordered by `id`),
   assigns them to the pull request and enqueues one `create_execution_by_plan` job per plan (`max_attempts=1`).
3. The job creates a check suite, stops the previous execution of the same plan and calls
   `POST /rest/api/latest/queue/<bamboo_ci_plan_name>` in Bamboo with the PR variables (`github_repo`, `github_pullreq`,
   `github_branch`, `github_merge_sha`, `github_base_sha`, `github_signature_secret`).
4. Once Bamboo reports the running jobs, a check run is created on GitHub for every row of `stage_configurations`, and
   each Bamboo job is attached to the stage whose `bamboo_stage_name` matches its Bamboo stage.

`ci:rerun` comments and check suite re-runs use the same rows (the PR's plans, or the repository's plans as fallback).

## Columns

| Column                | Required | Meaning                                                                                                      |
|-----------------------|:--------:|--------------------------------------------------------------------------------------------------------------|
| `bamboo_ci_plan_name` |   yes    | Bamboo **plan key** (`PROJECT-PLAN`, e.g. `TESTING-FRRCRAS`), not the display name                           |
| `github_repo_name`    |   yes    | Repository `full_name` exactly as GitHub sends it (`<owner>/<repo>`, case-sensitive)                         |
| `name`                |   yes    | Short label used in logs and, with `MULTI_PLAN=true` and several plans, as check run suffix (`<run> - name`) |
| `pull_request_id`     |    no    | Managed by the app (the PR that currently owns the plan). Leave it `NULL`                                    |
| `check_suite_id`      |    no    | Unused. Leave it `NULL`                                                                                      |
| `created_at`          |   yes    | Timestamp (no database default: set it to `now()`)                                                           |
| `updated_at`          |   yes    | Timestamp (no database default: set it to `now()`)                                                           |

## Prerequisites

- The GitHub App is installed on the repository and listed in `github_apps.toml` (`repo = "<owner>/<repo>"`), see
  [04](04-configuration-and-environment.md#github-app-configuration).
- The Bamboo plan exists and the service's Bamboo user can run it. Check it with the service's own client:

  ```bash
  python -m netdef_ci check-bamboo --plan PROJECT-PLAN
  ```

- The Bamboo plan accepts the variables listed above and its notification script signs the callback body with
  `github_signature_secret` and posts it to `/update/status` (step 6 of the GitHub App setup in
  [04](04-configuration-and-environment.md)).
- The Bamboo stage names are present in `stage_configurations` (next section).

## Stage configurations

`stage_configurations` is **global**: it is not linked to a plan, and every execution of every plan creates one check
run per row. Jobs whose Bamboo stage has no matching `bamboo_stage_name` are ignored. When the new Bamboo plan uses the
same stage names as the existing ones there is nothing to add; when it introduces new stages, add them:

```sql
INSERT INTO stage_configurations
    (bamboo_stage_name, github_check_run_name, position, mandatory, can_retry, start_in_progress, created_at, updated_at)
VALUES
    ('Build', 'Build', 1, true, true, false, now(), now());
```

| Column                  | Meaning                                                                                    |
|-------------------------|--------------------------------------------------------------------------------------------|
| `bamboo_stage_name`     | Stage name exactly as Bamboo reports it                                                    |
| `github_check_run_name` | Check run name shown on GitHub; keep it stable, `ci:retry` looks stages up by this name    |
| `position`              | Order of the stage; when a stage finishes successfully the one at `position + 1` continues |
| `mandatory`             | When a mandatory stage fails, is skipped or cancelled, every later stage is cancelled      |
| `can_retry`             | Whether `ci:retry` and re-runs may restart its jobs                                        |
| `start_in_progress`     | Mark the stage and its jobs `in_progress` right after creation instead of `queued`         |

Because the rows are global, a stage added for a new plan also appears (as a check run with no jobs) on the
repositories whose plans do not have it.

## Adding the plan

Connect to the service database (the `DATABASE_URL` of `/etc/netdef-ci/netdef-ci.env` in production) and insert the row:

```sql
INSERT INTO plans (bamboo_ci_plan_name, github_repo_name, name, created_at, updated_at)
VALUES ('PROJECT-PLAN', 'example-org/example-repo', 'Main tests', now(), now());
```

No restart or deploy is needed: plans are read on every webhook.

To run **several Bamboo plans for the same repository**, insert one row per plan with the same `github_repo_name`.
Each plan gets its own check suite and Bamboo execution. Set `MULTI_PLAN=true` so the check run names carry the plan
`name` as suffix (`Build - Main tests`, `Build - Extra tests`); otherwise the plans create check runs with identical names.

## Verifying

1. Confirm the row:

   ```sql
   SELECT id, name, bamboo_ci_plan_name, github_repo_name, pull_request_id FROM plans
   WHERE github_repo_name = 'example-org/example-repo';
   ```

2. Open (or push to) a pull request on the repository. The webhook delivery on GitHub must answer `200 Scheduled Plan
   Runs`; `422 No Plans associated…` means `github_repo_name` does not match `repository.full_name`.
3. Within a few seconds (`CREATE_EXECUTION_DELAY_SECONDS`) the `create_execution_by_plan` job starts the plan; the PR log
   shows `Starting Plan: <name>` and the check runs appear on GitHub. `Failed to create CI Plan` means Bamboo rejected the
   submission (wrong plan key, credentials, concurrent build limit); see the troubleshooting table in
   [09](09-operations.md).

## Changing or removing a plan

- **Point to another Bamboo plan:** `UPDATE plans SET bamboo_ci_plan_name = 'PROJECT-NEW', updated_at = now() WHERE id = <id>;`
  The next pull request event uses it; running executions are not affected.
- **Remove a plan:** existing `check_suites.plan_id` rows reference it, so deleting fails while it has history. To stop
  using it without losing history, detach it from the repository instead:
  `UPDATE plans SET github_repo_name = 'disabled/example-org/example-repo', pull_request_id = NULL, updated_at = now() WHERE id = <id>;`

Note that a plan row belongs to one pull request at a time (see [07](07-design-notes.md)): every event re-assigns the
repository's plans to the PR that sent it. This is expected and does not need any manual action.
