# 10 — Deploy with Ansible (dev and production)

Automation lives in `deploy/ansible/`. **Nothing was run against real servers**: addresses, repository and secrets are *placeholders*
(`REPLACE_WITH_…`) and the role's `assert` aborts if they remain in the inventory.

## Overview

```
deploy/ansible/
├── ansible.cfg  .ansible-lint
├── inventories/{dev,prod}/
│   ├── hosts.yml                          # server address (placeholder)
│   └── group_vars/all/{main.yml,vault.yml.example}
├── playbooks/{deploy.yml,rollback.yml,healthcheck.yml}
└── roles/
    ├── python_runtime/                    # builds CPython 3.15.2 (python.org, pinned SHA-256) in /opt/python/3.15.2
    └── netdef_ci/                         # user, config, release, venv, migrations, systemd, health check, cleanup
```

What the role installs (Debian/Ubuntu with systemd — the current infrastructure uses `apt`; `RedHat` only has the package list, **untested**):

| Item          | Detail                                                                                                                                                                                                                                                                                                |
|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Service user  | `netdef-ci` (system, `nologin`, no sudo); the code is `root:root` and read-only for it                                                                                                                                                                                                                |
| Directories   | `/opt/netdef-ci/{releases/<id>,current→release}`, `/etc/netdef-ci` (0750), `/etc/netdef-ci/keys` (`.pem` keys 0640 `root:netdef-ci`), `/var/log/netdef-ci/{prd,dev}`                                                                                                                                  |
| Configuration | `/etc/netdef-ci/netdef-ci.env` (0640, secrets from the Vault), `/etc/netdef-ci/github_apps.toml`                                                                                                                                                                                                      |
| Python/venv   | `/opt/python/3.15.2` (`make altinstall`, idempotent) and a per-release `venv` with `pip install --only-binary=:all: -r requirements.txt`                                                                                                                                                              |
| Processes     | `netdef-ci-web.service`, `netdef-ci-worker-{q0-3,q4-6,q7-9,create-by-plan,create-by-comment,create-by-command,timeout,topotest}.service` (units no longer listed are stopped and removed), `netdef-ci.target`, timers `netdef-ci-watchdog` and `netdef-ci-pr-sync`; `Restart=always`, enabled at boot |
| Hardening     | `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp/Devices`, empty `CapabilityBoundingSet=`, `RestrictAddressFamilies`, `UMask=0027`… (`systemd-analyze security`: 3.2 OK)                                                                                                         |
| Migrations    | `python -m netdef_ci migrate` with the **new** release, before switching the `current` link (additive, compatible with the previous release)                                                                                                                                                          |
| Restart       | the `Restart netdef-ci` handler only fires when config, unit or the `current` link changes                                                                                                                                                                                                            |
| Verification  | `/readyz` (with retries), `/healthz`, `/ping` and `active` state of each unit                                                                                                                                                                                                                         |
| Retention     | keeps `netdef_ci_keep_releases` releases (dev 3, prod 5)                                                                                                                                                                                                                                              |

## Prerequisites

- Controller: `ansible-core` (the role declares ≥ 2.16, but it was only exercised with 2.18 `--syntax-check`, 2.19 for convergence and 2.21 for `ansible-lint` 26.x, `production` profile). Only `ansible.builtin` modules — **there are no collections to install**.
- Server: Debian/Ubuntu with systemd, SSH access with sudo, outbound access to `python.org`, PyPI and the git repository (or a code tarball), reachable PostgreSQL (database and user already created; the role does **not** provision the database), inbound port opened/reverse proxy to the service port (dev 9292, prod 4667).
- Code: git repository reachable from the server (`netdef_ci_repo_url`; optional deploy key `netdef_ci_git_key_file`) **or** a tarball (`git archive`) uploaded by Ansible.

## Values that must be filled in

| Where                                       | Variable                       | Description                                                                |
|---------------------------------------------|--------------------------------|----------------------------------------------------------------------------|
| `inventories/<env>/hosts.yml`               | `ansible_host`, `ansible_user` | server and SSH user                                                        |
| `inventories/<env>/group_vars/all/main.yml` | `netdef_ci_repo_url`           | repository URL                                                             |
| same                                        | `netdef_ci_version`            | tag/commit (mandatory in production)                                       |
| same                                        | `netdef_ci_settings.CI_URL`    | Bamboo host used in links                                                  |
| same                                        | `netdef_ci_timers`             | schedules equivalent to the current cron                                   |
| `vault.yml` (encrypted)                     | `vault_netdef_ci_*`            | database, webhook secret (≥ 16 characters), GitHub Apps passwords and keys |

## Secrets with Ansible Vault

```bash
cd deploy/ansible
cp inventories/prod/group_vars/all/vault.yml.example inventories/prod/group_vars/all/vault.yml
$EDITOR inventories/prod/group_vars/all/vault.yml        # real values, only on your machine
ansible-vault encrypt inventories/prod/group_vars/all/vault.yml
# run with --ask-vault-pass or --vault-password-file .vault_pass (both kept out of git: see .gitignore)
```

`vault.yml` and `.vault_pass` are in `.gitignore`; only the `*.example` files (without credentials) are versioned.

## Exact commands

```bash
cd deploy/ansible

# local validations (no server)
ansible-playbook -i inventories/dev/hosts.yml  playbooks/deploy.yml --syntax-check
ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml --syntax-check
ansible-lint

# DEVELOPMENT — branch, tag or commit of your choice
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=main
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass --check --diff   # dry run

# PRODUCTION — explicit version (tag or SHA); one machine at a time (serial: 1), aborts on the first error
ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=v1.0.0

# code from a tarball instead of git
git archive --format=tar.gz -o /tmp/netdef-ci.tar.gz HEAD
ansible-playbook -i inventories/dev/hosts.yml playbooks/deploy.yml --ask-vault-pass \
  -e netdef_ci_source_strategy=archive -e netdef_ci_source_archive=/tmp/netdef-ci.tar.gz -e netdef_ci_release_id=$(git rev-parse --short=12 HEAD)

# verification at any time
ansible-playbook -i inventories/prod/hosts.yml playbooks/healthcheck.yml --ask-vault-pass
```

To only reconfigure without rebuilding Python: `--tags app`. Python is built only once (≈ 5–10 min; `python_runtime_optimizations=true` enables PGO and takes longer).

## Rollback

```bash
# go back to the previous release (history in /opt/netdef-ci/.release_history, stack-like)
ansible-playbook -i inventories/prod/hosts.yml playbooks/rollback.yml --ask-vault-pass
# or to a specific release
ansible-playbook -i inventories/prod/hosts.yml playbooks/rollback.yml --ask-vault-pass -e netdef_ci_rollback_to=<release-id>
```

The playbook switches the `current` link, restarts `netdef-ci.target` and runs the health check. The database is **not** rolled back (additive migrations). For database rollout notes, see `06-database-and-rollout.md`.

## Idempotency

`deploy.yml` can be repeated: with no changes, `changed=0` and no restart (handlers). Releases are named after the resolved commit (12 characters); the same commit reuses the directory and the venv.

## Validations performed (without real servers)

| Check                                                                                                                                                                                                                                                           | Result                                                                                                                                                                                                              |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ansible-playbook --syntax-check` (`deploy`, `rollback`, `healthcheck`; dev and prod)                                                                                                                                                                           | OK (ansible-core 2.18.18)                                                                                                                                                                                           |
| `ansible-lint` (`production` profile)                                                                                                                                                                                                                           | `0 failure(s), 0 warning(s)` in 40 files                                                                                                                                                                            |
| Convergence in a **Debian trixie container with systemd** (`deploy/ansible/tests/converge/run.sh`: podman `--privileged --systemd=always`, `local` connection inside the container, PostgreSQL in another container, `archive` strategy) — 1st run from scratch | `ok=53 changed=27 failed=0`: built Python 3.15.2, created user/directories, venv, units, applied migrations and passed the health check                                                                             |
| Idempotency: same release again                                                                                                                                                                                                                                 | `ok=44 changed=0 failed=0`                                                                                                                                                                                          |
| New release (new venv, link, history, restart) and repeat                                                                                                                                                                                                       | `changed=6` → repeat `changed=0`                                                                                                                                                                                    |
| Rollback                                                                                                                                                                                                                                                        | `ok=13 changed=3 failed=0`; link returns to the previous release and `/readyz` answers `ready`; two consecutive rollbacks walk the history like a stack                                                             |
| Final state observed in the container                                                                                                                                                                                                                           | 5 services `active`, processes running as `netdef-ci`, venv and `/opt/python/3.15.2` with Python 3.15.2, signed ping `PONG!`, `/metrics` with Basic Auth, watch-dog timer scheduled, `systemd-analyze security` 3.2 |

Validation limitations: there was no real SSH access, real GitHub App, Bamboo or Slack; the container uses a `local` connection (it does not exercise SSH/`become`); the `RedHat` configuration and the use of `--check` on new hosts (the `--check` of the `pip`/`command` module depends on the release already existing) were not exercised. The container needed `--privileged` (rootless) because of systemd's sandbox options.
