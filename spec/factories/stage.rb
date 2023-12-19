#  SPDX-License-Identifier: BSD-2-Clause
#
#  stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :stage do
    name { Faker::App.name }
    status { 0 }
    check_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }

    configuration { create(:stage_configuration, github_check_run_name: name) }

    trait :failure do
      status { :failure }
    end

    trait :success do
      status { :success }
    end

    trait :build do
      name { 'Build' }
    end

    trait :test do
      name { 'TopoTest AMD' }
    end

    trait :can_not_retry do
      configuration { create(:stage_configuration, can_retry: false) }
    end

    trait :with_check_suite do
      check_suite { create(:check_suite) }
    end

    trait :with_job do
      jobs { [create(:ci_job)] }
    end
  end
end
