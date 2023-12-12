#  SPDX-License-Identifier: BSD-2-Clause
#
#  bamboo_stage_translation.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :bamboo_stage_translation do
    bamboo_stage_name { Faker::App.name }
    github_check_run_name { Faker::App.name }
    start_in_progress { false }
    can_retry { true }
  end
end

