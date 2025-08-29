#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :pull_request do
    author { Faker::Name.name }
    github_pr_id { 1 }
    branch_name { Faker::App.name }
    repository { 'Unit/Test' }
    plans { [create(:plan)] }

    trait :with_check_suite do
      after(:create) do |pr|
        create(:check_suite, :with_running_ci_jobs, pull_request: pr)
      end
    end
  end
end
