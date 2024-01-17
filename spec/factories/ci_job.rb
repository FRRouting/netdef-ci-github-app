#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :ci_job do
    name { Faker::App.name }
    status { 0 }
    job_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }
    check_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }

    check_suite
    stage { create(:stage, check_suite: check_suite) }

    trait :topotest_failure do
      after(:create) do |ci_job|
        create(:topotest_failure, ci_job: ci_job)
      end
    end

    trait :in_progress do
      status { 'in_progress' }
    end

    trait :failure do
      status { 'failure' }
    end

    trait :success do
      status { 'success' }
    end
  end
end
