#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_ci_app.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

# Bamboo CI libs
require_relative 'bamboo_ci/api'
require_relative 'bamboo_ci/plan_run'
require_relative 'bamboo_ci/result'
require_relative 'bamboo_ci/retry'
require_relative 'bamboo_ci/running_plan'
require_relative 'bamboo_ci/stop_plan'

# GitHub libs
require_relative 'github/parsers/pull_request_commit'
require_relative 'github/re_run/base'
require_relative 'github/re_run/command'
require_relative 'github/re_run/comment'
require_relative 'github/build_plan'
require_relative 'github/check'
require_relative 'github/retry/command'
require_relative 'github/retry/comment'
require_relative 'github/update_status'
require_relative 'github/plan_execution/finished'
require_relative 'github/user_info'
require_relative 'github/build/skip_old_tests'
require_relative 'github/topotest_failures/retrieve_error'

# Helpers libs
require_relative 'helpers/configuration'
require_relative 'helpers/github_logger'
require_relative 'helpers/request'
require_relative 'helpers/sinatra_payload'
require_relative 'helpers/telemetry'

# Workers
require_relative '../workers/ci_job_status'
require_relative '../workers/ci_job_fetch_topotest_failures'

# Slack libs
require_relative 'slack/slack'

# Slack Bot libs
require_relative 'slack_bot/slack_bot'
