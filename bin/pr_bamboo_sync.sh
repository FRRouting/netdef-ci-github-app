#!/bin/bash
#
#  SPDX-License-Identifier: BSD-2-Clause
#
#  pr_bamboo_sync.sh
#  Part of NetDEF CI System
#
#  Validates Bamboo CI execution status for PRs whose GitHub Actions
#  check suites were active between 24h and 2h ago.
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")

# shellcheck disable=SC2164
cd /home/githubchecks/server
RACK_ENV=production ruby workers/pr_bamboo_sync.rb