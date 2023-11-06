#  SPDX-License-Identifier: BSD-2-Clause
#
#  topotest_failure.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :pull_request_subscription do
    slack_user_id { 123 }
    rule { 'notify' }
    target { pull_request.github_pr_id }
    notification { 'all' }

    pull_request
  end
end
