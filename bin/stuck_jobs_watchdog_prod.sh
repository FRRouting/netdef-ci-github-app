#
#  SPDX-License-Identifier: BSD-2-Clause
#
#  stuck_jobs_watchdog_prod.sh
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#/bin/bash

# shellcheck disable=SC2164
cd /home/githubchecks/server
RACK_ENV=production ruby workers/stuck_jobs_watchdog.rb