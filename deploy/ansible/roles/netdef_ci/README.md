<!--
  SPDX-License-Identifier: BSD-2-Clause

  README.md
  Part of NetDEF CI System

  Copyright (c) 2026 by
  Network Device Education Foundation, Inc. ("NetDEF")
-->

# netdef_ci role (Ruby)

Installs the NetDEF CI GitHub App (Ruby/Sinatra) as a set of systemd services (Puma web, one delayed_job worker per
queue group, periodic timers) from a git revision or a source archive, in `releases/<id>` directories with a `current`
symlink. Same layout and variables as the Python deployment, with every name on the host prefixed by
`netdef_ci_name` (`netdef-ci-ruby`). See `doc/general/ansible-deploy.md`.
