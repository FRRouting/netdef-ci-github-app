#  SPDX-License-Identifier: BSD-2-Clause
#
#  audit_retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :audit_retry do
    github_username { Faker::Games::Dota.hero }
    github_id { Faker::Alphanumeric.alpha }
    github_type { 'User' }
    retry_type { 'full' }

    check_suite { create(:check_suite) }
  end
end

