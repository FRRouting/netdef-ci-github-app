# NetDEF CI GitHub App (Python)

Server that connects **GitHub Pull Requests** to **Bamboo CI**: it receives webhooks, triggers the Bamboo plans, keeps the
*Check Runs* on GitHub up to date, consolidates the results sent by Bamboo and notifies Slack.

- Python **3.15.2** · FastAPI + uvicorn · SQLAlchemy 2 + Alembic + PostgreSQL · httpx · PyJWT · prometheus-client
- Own PostgreSQL job queue (`run_at`, named queues, retries with back-off), no Redis
- Tests: **252 passing**, **94 %** coverage, `ruff` and `mypy` clean · Deploy: **Ansible** (dev and production)

Full documentation in [`doc/`](doc/): overview and diagrams (`01`), feature and test matrix (`02`), technical decisions (`03`),
configuration/GitHub App/secrets (`04`), endpoints (`05`), database and rollout (`06`), design notes (`07`),
persistence/concurrency (`08`), operations and troubleshooting (`09`), Ansible deploy (`10`), testing (`11`), limitations (`12`).

## Quick start (development)

Prerequisites: Python 3.15 (`python3.15`), a reachable PostgreSQL.

```bash
python3.15 -m venv .venv && . .venv/bin/activate
pip install --only-binary=:all: -r requirements-dev.txt      # runtime only: requirements.txt

cp .env.example .env                       # adjust DATABASE_URL, WEBHOOK_SECRET, BAMBOO_*, SLACK_*  (the example holds fictitious values)
cp github_apps.example.toml github_apps.toml   # App ID, .pem key path and repository
export PYTHONPATH=src

python -m netdef_ci check-config           # validates configuration, keys and database
python -m netdef_ci migrate                # creates/updates the schema (adopts existing databases)

python -m uvicorn --factory netdef_ci.web.app:app_factory --host 0.0.0.0 --port 9292   # web
python -m netdef_ci worker                 # in another terminal: processes the queue (--queues 0,1,2,3 for one range)
python -m netdef_ci watch-dog              # reconciliation (in production: systemd timer)
```

`make run`, `make worker`, `make migrate`, `make check` and `make smoke` wrap the commands above.
Register the repository's plans and stages in `plans` (`bamboo_ci_plan_name`, `github_repo_name`, `name`) and `stage_configurations` (see `doc/04`).

Console commands:

```bash
python -m netdef_ci org create NetDEF --contact-name "Jane Doe"
python -m netdef_ci user add-to-org <github-login> NetDEF
python -m netdef_ci user link-slack <github-login> <slack-user>
python -m netdef_ci single-sync PROJ-PLAN-123      # re-syncs one Bamboo execution
```

## Tests and quality

```bash
make check                       # ruff + mypy + pytest (+ coverage >= 90 %)
scripts/test-with-podman.sh      # the same gate with Python 3.15.2 and PostgreSQL in containers
```

Details and results: [`doc/11-testing.md`](doc/11-testing.md).

## Deploy

```bash
cd deploy/ansible
# 1) fill in inventories/<env>/hosts.yml and group_vars/all/main.yml (REPLACE_WITH_... placeholders)
# 2) create and encrypt the vault: inventories/<env>/group_vars/all/vault.yml  (template: vault.yml.example)
ansible-playbook -i inventories/dev/hosts.yml  playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=<branch|tag|sha>
ansible-playbook -i inventories/prod/hosts.yml playbooks/deploy.yml --ask-vault-pass -e netdef_ci_version=<tag|sha>
ansible-playbook -i inventories/prod/hosts.yml playbooks/rollback.yml --ask-vault-pass
```

Installation, upgrade, rollback and health check: [`doc/10-ansible-deploy.md`](doc/10-ansible-deploy.md).
**No real server was touched**; the automation was validated with `--syntax-check`, `ansible-lint` and a convergence run in a systemd container.

## Security

Secrets never go into the repository (`.env`, `*.pem`, `vault.yml` are in `.gitignore`); webhooks are validated with HMAC-SHA256 over the raw
body using constant-time comparison; logs redact tokens/secrets; the service runs unprivileged with a systemd sandbox.
Secret management and rotation: [`doc/04-configuration-and-environment.md`](doc/04-configuration-and-environment.md).

## Status

Functionality is demonstrated by tests (matrix in `doc/02`), with design notes in `doc/07` and open items in `doc/12`
(real GitHub/Bamboo/Slack integration and server deployment not validated).

License: BSD-2-Clause — Network Device Education Foundation, Inc. ("NetDEF").
