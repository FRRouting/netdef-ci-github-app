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
    check_ref { rand(1_000_000) }

    check_suite

    trait :checkout_code do
      name { 'Checkout Code' }
    end

    trait :in_progress do
      status { 'in_progress' }
    end

    trait :failure do
      status { 'failure' }
    end
  end
end
