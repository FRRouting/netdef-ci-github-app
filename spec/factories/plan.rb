#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :plan do
    name { Faker::App.name }
    bamboo_ci_plan_name { Faker::App.name }
    github_repo_name { Faker::App.name }
  end
end
