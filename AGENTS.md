# AGENTS.md — AI Agent Collaboration Guide

This file provides context and conventions for AI coding agents (Claude Code, Copilot, Cursor, etc.) contributing to this project. Follow these patterns to produce code that is consistent with the existing codebase.

---

## Project Overview

**netdef-ci-github-app** is a Ruby/Sinatra webhook server that bridges GitHub pull requests and a Bamboo CI system. It receives GitHub events, triggers CI builds, polls for results, updates GitHub Check Runs, and sends Slack notifications.

**Stack:**
- Ruby 3.1+ / Sinatra / Rack / Puma
- PostgreSQL via `otr-activerecord` (ActiveRecord without Rails)
- Delayed Job (background workers — not Sidekiq)
- Octokit (GitHub API)
- RSpec + FactoryBot + WebMock (tests)
- Rubocop 1.56 (linting — enforced in CI)

---

## Repository Layout

```
app/github_app.rb          # Sinatra entry point — routes only, no business logic
lib/
  bamboo_ci/               # All Bamboo REST API interactions
  github/                  # GitHub webhook handlers and Check API wrappers
    build/                 # Submodules for build orchestration
    retry/                 # Comment-triggered retry logic
    re_run/                # Check suite re-run logic
    plan_execution/        # Handlers for execution completion
    topotest_failures/     # Failure log parsers
    parsers/               # PR commit parsers
  models/                  # ActiveRecord models (12 models)
  helpers/                 # Cross-cutting concerns: config, logging, metrics, auth
  slack/                   # Slack API client
  slack_bot/               # Notification formatters
workers/                   # Delayed Job worker classes
spec/
  app/                     # Integration tests (Rack::Test)
  lib/                     # Unit tests — mirror lib/ structure
  workers/                 # Worker unit tests
  factories/               # FactoryBot factories
  support/                 # RSpec helpers (factory_bot.rb, webmock.rb)
config/
  setup.rb                 # Boot sequence — load order matters here
  delayed_job.rb           # Worker tuning (max_attempts, sleep_delay, max_run_time)
  database.yml             # PostgreSQL connection by environment
db/migrate/                # Numbered migrations only — never edit schema.rb directly
```

---

## Code Conventions

### File Header

Every Ruby file starts with this exact header block (replace `filename.rb` and the year accordingly):

```ruby
#  SPDX-License-Identifier: BSD-2-Clause
#
#  filename.rb
#  Part of NetDEF CI System
#
#  Copyright (c) <year> by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true
```

Include this header on all new files. The order matters: license identifier first, then filename + project line, then copyright, then frozen string literal.

### Naming

| Construct | Convention | Example |
|-----------|-----------|---------|
| Classes / Modules | PascalCase | `BambooCi::PlanRun` |
| Methods | snake_case | `fetch_executions` |
| Constants | UPPER_SNAKE_CASE | `MAX_RETRY_ATTEMPTS` |
| DB tables | plural snake_case | `ci_jobs`, `check_suites` |
| AR models | singular PascalCase | `CiJob`, `CheckSuite` |
| Files | snake_case matching class | `plan_run.rb` for `PlanRun` |

### Modules & Namespacing

Group classes by domain, not by layer:

```
lib/bamboo_ci/api.rb       → module BambooCi, class Api
lib/github/check.rb        → module Github, class Check
lib/slack_bot/stage.rb     → module SlackBot, class Stage
```

Do not put business logic in `app/github_app.rb`. Routes delegate immediately:

```ruby
# Good
post '/*' do
  Github::BuildPlan.new(payload).create
end

# Bad — inline logic in the route
post '/*' do
  pull_request = PullRequest.find_or_create_by(...)
  # ... 50 lines of logic
end
```

### Method Length

Rubocop enforces **20 lines max**. Extract private helpers rather than writing long methods.

### Class / Module Length

Rubocop enforces **200 lines max**. Split responsibilities into submodules (see `lib/github/build/`, `lib/github/retry/`).

### No Documentation Cops

`Style/Documentation` is disabled. Do not add class-level docblock comments unless there is a non-obvious invariant to explain. One-line comments for _why_, not _what_.

---

## Models

### Enums

Status enums follow this shared pattern across `CiJob`, `Stage`, and `AuditStatus`:

```ruby
enum status: {
  queued:      0,
  in_progress: 1,
  success:     2,
  cancelled:  -1,
  failure:    -2,
  skipped:    -3
}
```

Use the symbol form everywhere: `ci_job.success!`, `stage.in_progress?`, `CiJob.where(status: :failure)`.

### Associations

Declare associations at the top of the model, before validations and scopes:

```ruby
class CiJob < ApplicationRecord
  belongs_to :check_suite
  belongs_to :stage
  has_many   :topotest_failures, dependent: :destroy
  has_many   :audit_statuses,    as: :auditable, dependent: :destroy

  enum status: { ... }

  scope :failure_only, -> { where(status: :failure) }
end
```

### Migrations

- Always create a numbered migration: `rails generate migration AddColumnToTable` or write by hand following `db/migrate/` naming.
- Never edit `db/schema.rb` by hand — it is regenerated by `rake db:migrate:reset`.
- Validate that `schema.rb` matches migrations in CI: `diff <(rake db:schema:dump) db/schema.rb`.

---

## Workers (Delayed Job)

Workers are plain Ruby classes enqueued with `.delay`:

```ruby
# Enqueue
CreateExecutionByPlan.new.delay(queue: 2).perform(check_suite_id: suite.id)

# Worker
class CreateExecutionByPlan
  def perform(check_suite_id:)
    suite = CheckSuite.find(check_suite_id)
    # ...
  end
end
```

**Rules:**
- Workers live in `workers/`, not in `lib/`.
- Workers do not inherit from `ActiveJob::Base` — use plain Ruby classes.
- Keep workers thin: delegate logic to `lib/` classes.
- Queue numbers 0–9 are meaningful (see `config.ru` for priority tiers).
- Max 5 attempts, 5-minute timeout per job (configured in `config/delayed_job.rb`).

---

## Testing

### Framework

RSpec with `--format=documentation --order=random`. Always run with `bundle exec rspec`.

### Test File Location

Mirror the source path:

```
lib/github/build_plan.rb        → spec/lib/github/build_plan_spec.rb
workers/ci_job_status.rb        → spec/workers/ci_job_status_spec.rb
app/github_app.rb               → spec/app/github_app_spec.rb
```

### Structure Template

```ruby
# frozen_string_literal: true

describe Github::BuildPlan do
  let(:payload) { create(:pull_request_payload) }

  describe '#create' do
    context 'when the repository is configured' do
      before { allow_any_instance_of(Github::Check).to receive(:create).and_return(true) }

      it 'creates a check suite' do
        expect { described_class.new(payload).create }.to change(CheckSuite, :count).by(1)
      end
    end

    context 'when the repository is not configured' do
      it 'returns early without creating records' do
        expect { described_class.new(payload).create }.not_to change(CheckSuite, :count)
      end
    end
  end
end
```

### Factories

Factories live in `spec/factories/`. Use traits for associations, not nested factories:

```ruby
FactoryBot.define do
  factory :check_suite do
    commit_sha_ref { Faker::Alphanumeric.alphanumeric(number: 40) }
    author         { Faker::Internet.username }

    trait :with_ci_jobs do
      after(:create) do |suite|
        create_list(:ci_job, 3, check_suite: suite)
      end
    end
  end
end
```

### HTTP Mocking

All external HTTP calls must be mocked with WebMock. No real network calls in tests:

```ruby
before do
  stub_request(:post, %r{bamboo/rest/api/latest/queue})
    .to_return(status: 200, body: { buildResultKey: 'PROJ-123' }.to_json)
end
```

### Coverage Requirements

SimpleCov enforces **90% branch coverage minimum per group**. Use `:nocov:` only for genuinely untestable blocks (e.g., rescue blocks for infrastructure failures):

```ruby
# :nocov:
rescue StandardError => e
  logger.error(e.message)
# :nocov:
end
```

---

## Configuration

Runtime configuration is loaded from `config.yml` (not committed — see `config_template.yml`):

```ruby
config = GitHubApp::Configuration.instance
config.reload                           # re-reads YAML from disk
config.all_logins                       # GitHub app login names
config.bamboo_url                       # Bamboo base URL
```

Never hardcode URLs, credentials, or repo names. Always read from `GitHubApp::Configuration.instance`.

---

## Logging

Use the project logger — do not use `puts` or `p`:

```ruby
logger = GithubLogger.instance.create('github_app.log', Logger::INFO)
logger.info { "[#{self.class}] Starting plan #{plan.id}" }
logger.error { "[#{self.class}] Failed: #{e.message}" }
```

Log file names map to components (see `lib/helpers/github_logger.rb`). Use the closest existing log file for your component.

---

## Metrics

Increment Prometheus counters/histograms for any new external call or user-visible operation:

```ruby
PrometheusMet.instance.http_requests.increment(labels: { method: 'POST', status: '200' })
```

Do not add new metric names without first checking `lib/helpers/prometheus_metrics.rb` for an existing one that fits.

---

## CI/CD

The GitHub Actions workflow (`.github/workflows/ruby.yml`) runs on every push/PR:

1. **Rubocop** — lint check via reviewdog (inline PR comments on violations).
2. **RSpec** — full test suite with a real PostgreSQL 14 service.

Before opening a PR:

```bash
bundle exec rubocop                    # must pass with zero offenses
bundle exec rspec                      # must pass at ≥90% coverage
rake db:migrate:reset                  # verify migrations apply cleanly
```

---

## Common Pitfalls

- **Do not use `ActiveJob`** — this project uses Delayed Job with plain Ruby workers.
- **Do not call external services from within a Sinatra route** — enqueue a worker instead.
- **Do not modify `db/schema.rb` by hand** — generate a migration.
- **Do not add logic to `app/github_app.rb`** — it should only instantiate and delegate.
- **Do not stub `Time.now` or `Date.today` globally** — use `Timecop` if a test requires time control (not currently a dependency — add it if needed).
- **Do not create new queue numbers** beyond 0–9 without updating `config.ru`.
- **Run `rubocop -A` before committing** — unformatted code fails CI immediately.

---

## Checklist for New Features

- [ ] New files include the frozen string literal comment and SPDX header.
- [ ] Business logic lives in `lib/`, not in `app/`, `workers/`, or models.
- [ ] New ActiveRecord model includes a migration and status enum (if applicable).
- [ ] New Delayed Job worker lives in `workers/` and delegates to `lib/`.
- [ ] External HTTP calls are wrapped in a class under `lib/bamboo_ci/` or `lib/github/`.
- [ ] Tests mirror the source path and achieve ≥90% branch coverage.
- [ ] WebMock stubs cover all new HTTP calls in tests.
- [ ] `rubocop` passes with no new offenses.
- [ ] `rake db:migrate:reset && bundle exec rspec` passes locally.