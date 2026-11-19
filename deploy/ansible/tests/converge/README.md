<!--
  SPDX-License-Identifier: BSD-2-Clause

  README.md
  Part of NetDEF CI System

  Copyright (c) 2026 by
  Network Device Education Foundation, Inc. ("NetDEF")
-->

# Convergence test (local, no real servers)

`run.sh` builds a Debian trixie image with systemd and ansible-core, starts it privileged (rootless podman), starts a
PostgreSQL container and runs `playbooks/deploy.yml` / `rollback.yml` / `stop.yml` / `start.yml` against `localhost`
**inside** the container. It checks idempotency (`changed=0` on repeated runs), a new release, a signed GitHub `ping`,
`/metrics`, one watch-dog run, the rollback and stopping/starting the services. Requires podman and network access
(cache.ruby-lang.org, rubygems.org, docker.io); the first run compiles Ruby 3.3.13 (~5-10 min). All credentials in
`vault.yml` are fictitious.
