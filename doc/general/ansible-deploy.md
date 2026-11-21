# Deploy with Ansible (dev and production)

Automation lives in `deploy/ansible/`. It mirrors the deployment of the Python application (same playbooks, role
layout and variable names) so operators use the same commands for both. **Nothing was run against real servers**:
production addresses, repository and secrets are *placeholders* (`REPLACE_WITH_…`) and the role's `assert` aborts if
they remain in the inventory.

## Overview

```
deploy/ansible/
├── ansible.cfg  .ansible-lint  .gitignore
├── inventories/{dev,prod_frr_public}/
│   ├── hosts.yml                          # server address (placeholder in prod_frr_public)
│   └── group_vars/all/{main.yml,vault.yml.example}
├── playbooks/{deploy.yml,rollback.yml,healthcheck.yml,stop.yml,start.yml}
├── roles/
│   ├── ruby_runtime/                      # builds Ruby 3.3.13 (cache.ruby-lang.org, pinned SHA-256) in /opt/ruby/3.3.13
│   └── netdef_ci/                         # user, config, release, gems, migrations, systemd, health check, cleanup
└── tests/converge/                        # local test in a systemd container (no real server)
```

## Differences from the Python deployment

| Topic          | Ruby deployment                                                                                                                                   |
|----------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| Names on host  | Everything is prefixed by `netdef_ci_name` (`netdef-ci-ruby`): user, `/opt`, `/etc`, `/var/log`, units. Both applications can share a server.    |
| Bamboo         | The code calls Bamboo at `https://127.0.0.1` (`lib/bamboo_ci`), so the server **is** the Bamboo host. There is no `prod_private` inventory.       |
| Configuration  | `config.yml`, `database.yml` and `~/.netrc` (instead of an env file): see the table below.                                                        |
| Runtime        | Ruby built from source; gems installed per release with Bundler in deployment mode (`vendor/bundle`, without `development`/`test`).               |
| Workers        | One `rake jobs:work` per queue group (`QUEUES=`); the embedded workers of `config.ru` are disabled with `NETDEF_CI_EMBEDDED_WORKERS=false`.        |
| Health check   | `/ping`, `/metrics` with Basic Auth (reads `delayed_jobs`, so it proves the database is reachable) and `active` state of each unit.               |

## What the role installs

| Item          | Detail                                                                                                                                                                                                                       |
|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Service user  | `netdef-ci-ruby` (system, `nologin`, no sudo), home `/var/lib/netdef-ci-ruby`; the code is `root:root` and read-only for it                                                                                                |
| Directories   | `/opt/netdef-ci-ruby/{releases/<id>,current→release}`, `/etc/netdef-ci-ruby` (0750), `/etc/netdef-ci-ruby/keys` (`.pem` 0640 `root:netdef-ci-ruby`), `/var/log/netdef-ci-ruby/{prd,dev}`, `/var/lib/netdef-ci-ruby/state` |
| Configuration | `/etc/netdef-ci-ruby/config.yml` (webhook secret, GitHub Apps, metrics credentials, `ci.url`, port), `/etc/netdef-ci-ruby/database.yml`, `~/.netrc` (0600: Bamboo as `ci1.netdef.org`, Slack as `slack_bot.netdef.org`); the Bamboo 12 service account (`vault_netdef_ci_bamboo_client_id/client_secret`) goes to the env file as `BAMBOO_CLIENT_ID`/`BAMBOO_CLIENT_SECRET`/`BAMBOO_OAUTH_SCOPE` and replaces the netrc credentials      |
| Release links | the code reads/writes some paths relative to its directory; each release gets symlinks: `config.yml`, `config/database.yml`, `logs/`, `tmp/`, `puma.pid`, `.session.key`, `telemetry.json`, `watch_dog.log`                  |
| Ruby/gems     | `/opt/ruby/3.3.13` (idempotent), the Bundler version of `Gemfile.lock` (`BUNDLED WITH`), `bundle install` into `<release>/vendor/bundle`                                                                                     |
| Processes     | `netdef-ci-ruby-web.service` (Puma, `WEB_CONCURRENCY` workers), `netdef-ci-ruby-worker-{q0-1,q2-3,q4-5,q6-7,q8-9,create-by-plan,create-by-comment,create-by-command,timeout,topotest,pending-jobs,jobs-without-webhook}.service`, `netdef-ci-ruby.target`, timers `netdef-ci-ruby-watchdog` and `netdef-ci-ruby-pr-sync` |
| Hardening     | `NoNewPrivileges`, `ProtectSystem=strict` (writable: log and state directories), `ProtectHome`, `PrivateTmp/Devices`, empty `CapabilityBoundingSet=`, `RestrictAddressFamilies`, `UMask=0027`…                             |
| Migrations    | `bundle exec rake db:migrate` with the **new** release, before switching `current` (`netdef_ci_run_migrations: false` to skip)                                                                                              |
| Restart       | the `Restart netdef-ci` handler only fires when config, a unit or the `current` link changes                                                                                                                                 |
| Retention     | keeps `netdef_ci_keep_releases` releases (dev 3, prod 5)                                                                                                                                                                     |

Every queue used by the code must be in some worker of `netdef_ci_job_workers`, or its jobs never run. The queues are
`0`–`9` (status updates, `github_pr_id % 10`), `create_execution_by_plan`, `create_execution_by_comment`,
`create_execution_by_command`, `timeout_execution`, `fetch_topotest_failures`, `sync_pending_jobs` and
`poll_jobs_without_webhook`.

## Prerequisites

- Controller: `ansible-core` ≥ 2.16 (exercised with 2.18 for `--syntax-check` and with the Debian trixie package in the
  convergence test). Only `ansible.builtin` modules: there are no collections to install.
- Server: Debian/Ubuntu with systemd, the Bamboo host (see above), SSH access with sudo, outbound access to
  `cache.ruby-lang.org`, `rubygems.org` and the git repository (or a code tarball), reachable PostgreSQL (database and
  user already created; the role does **not** provision the database), inbound port opened or a reverse proxy to it.

## Values that must be filled in

| Where                                       | Variable                       | Description                                                       |
|---------------------------------------------|--------------------------------|-------------------------------------------------------------------|
| `inventories/<env>/hosts.yml`               | `ansible_host`, `ansible_user` | server and SSH user                                               |
| `inventories/<env>/group_vars/all/main.yml` | `netdef_ci_repo_url`           | repository URL                                                    |
| same                                        | `netdef_ci_version`            | tag/commit (mandatory in production)                              |
| same                                        | `netdef_ci_ci_host`            | Bamboo host used in `https://<host>/browse/<KEY>` links           |
| same                                        | `netdef_ci_timers`             | schedules replacing the cron entries                              |
| same                                        | `netdef_ci_legacy_units`       | units of the manual installation to stop (optional)               |
| `vault.yml` (encrypted)                     | `vault_netdef_ci_*`            | database, webhook secret (≥ 16 characters), Bamboo, Slack, Apps   |

The vault uses the same variable names as the Python deployment; a `postgresql+psycopg://` database URL is accepted and
rewritten to `postgresql://`.

## Secrets with Ansible Vault

```bash
cd deploy/ansible
cp inventories/prod_frr_public/group_vars/all/vault.yml.example inventories/prod_frr_public/group_vars/all/vault.yml
$EDITOR inventories/prod_frr_public/group_vars/all/vault.yml        # real values, only on your machine
ansible-vault encrypt inventories/prod_frr_public/group_vars/all/vault.yml
# run with --ask-vault-pass or --vault-password-file .vault_pass (both kept out of git: see deploy/ansible/.gitignore)
```

## Exact commands

```bash
cd deploy/ansible

# local validations (no server)
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --syntax-check
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/deploy.yml --syntax-check
ansible-lint

# DEVELOPMENT — branch, tag or commit of your choice
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=master
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass --check --diff   # dry run

# PRODUCTION — explicit version (tag or SHA); one machine at a time (serial: 1), aborts on the first error
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=v1.0.0

# code from a tarball instead of git
git archive --format=tar.gz -o /tmp/netdef-ci-ruby.tar.gz HEAD
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass \
  -e netdef_ci_source_strategy=archive -e netdef_ci_source_archive=/tmp/netdef-ci-ruby.tar.gz -e netdef_ci_release_id=$(git rev-parse --short=12 HEAD)

# verification at any time
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/healthcheck.yml --ask-vault-pass
```

To only reconfigure without checking Ruby again: `--tags app`. Ruby is built only once (≈ 5–10 min).

## Moving from the manual installation

Today production runs `deployment/github_server.service` (user `githubchecks`, port 4667) and cron entries for
`bin/watch_dog_prod.sh` and `bin/pr_bamboo_sync.sh`. On the first deploy:

1. Set `netdef_ci_legacy_units: [github_server.service]` in the inventory: the role stops and disables it before the new
   services start (both would compete for the port and the jobs).
2. Remove the cron entries by hand: the `netdef-ci-ruby-watchdog` and `netdef-ci-ruby-pr-sync` timers replace them.
3. Point `vault_netdef_ci_database_url` at the existing database; the migrations already applied are skipped.

## Rollback

```bash
# go back to the previous release (history in /opt/netdef-ci-ruby/.release_history, stack-like)
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/rollback.yml --ask-vault-pass
# or to a specific release
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/rollback.yml --ask-vault-pass -e netdef_ci_rollback_to=<release-id>
```

The playbook switches the `current` link, restarts `netdef-ci-ruby.target` and runs the health check. The database is
**not** rolled back. The units are not rendered again, so the restored release runs with the units of the newest one:
their `ExecStart` lines (`bundle exec rackup config.ru`, `bundle exec rake jobs:work`, `bundle exec ruby workers/…`)
must exist in every release. A release older than the `NETDEF_CI_EMBEDDED_WORKERS` / `QUEUES` changes would start its
embedded workers and process every queue in every worker.

## Stopping the application (Ruby ↔ Python transition)

```bash
# stop every process: timers, web service, job workers
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/stop.yml --ask-vault-pass
# same, but the services come back on the next reboot
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/stop.yml --ask-vault-pass -e netdef_ci_stop_disable=false

# start again (enables and starts the services and the enabled timers, then runs the health check)
ansible-playbook -i inventories/prod_frr_public/hosts.yml playbooks/start.yml --ask-vault-pass
```

`stop.yml` stops the timers, then the web service, then the target and the job workers (a worker finishes its running
job, up to `TimeoutStopSec=330`), disables them when `netdef_ci_stop_disable` is true and fails if anything is still
active. It removes nothing. Never run the workers of both applications against the same database: they would take
each other's `delayed_jobs` rows.

## Idempotency

`deploy.yml` can be repeated: with no changes, `changed=0` and no restart. Releases are named after the resolved commit
(12 characters); the same commit reuses the directory and its gems.

## Local convergence test

`deploy/ansible/tests/converge/run.sh` (podman, no real server): Debian trixie with systemd in a privileged container,
PostgreSQL 17 in another one, the `archive` strategy. It deploys, repeats (`changed=0`), deploys a second release,
sends a signed GitHub `ping`, reads `/metrics`, runs the watch-dog once, rolls back, stops twice and starts again.

Results of the last run (ansible-core from Debian trixie, Ruby 3.3.13 built from source):

| Step                                              | Result                                                                         |
|---------------------------------------------------|--------------------------------------------------------------------------------|
| First deploy (builds Ruby, gems, migrations)      | `ok=68 changed=34 failed=0`                                                    |
| Same release again                                | `changed=0`                                                                    |
| New release, then again                           | `changed=9` → `changed=0`                                                      |
| Signed GitHub `ping` / wrong signature            | `PONG!` / `401`                                                                |
| Watch-dog and pr-sync services                    | `success`                                                                      |
| Rollback                                          | `changed=3`; `current` back to the previous release, units `active`            |
| Stop, stop again, start                           | `changed=4` → `changed=0` (all `inactive`/`disabled`) → `changed=2`, `active`  |
| Queues                                            | a job in queue `7` runs; one in an unlisted queue is not taken by any worker   |
| `netdef_ci_legacy_units: [github_server.service]` | the fake legacy unit ends `inactive` and `disabled`                            |
| `systemd-analyze security` (web unit)             | 3.2 OK                                                                         |

Not exercised: real SSH/`become` (the container uses a `local` connection), the git strategy, real GitHub, Bamboo and
Slack, the `RedHat` package list, and `ansible-lint`.

