# Convergence test (local, no real servers)

`run.sh` builds a Debian trixie image with systemd and ansible-core, starts it privileged (rootless podman), starts a PostgreSQL
container and runs `playbooks/deploy.yml` / `rollback.yml` against `localhost` **inside** the container, checking idempotency
(`changed=0` on repeated runs), a new release and the rollback. Requires podman and network access (python.org, PyPI, docker.io);
the first run compiles Python 3.15.2 (~5-10 min). All credentials in `vault.yml` are fictitious.
