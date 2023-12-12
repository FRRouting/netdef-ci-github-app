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

    parent_stage { create(:parent_stage, check_suite: check_suite) }
    check_suite

    trait :checkout_code do
      name { 'Checkout Code' }
      stage { true }
    end

    trait :build_stage do
      name { 'Build' }
      stage { true }

      after(:create) do
        create(:bamboo_stage_translation, github_check_run_name: 'Build')
      end
    end

    trait :tests_stage do
      name { 'Tests' }
      stage { true }

      after(:create) do
        create(:bamboo_stage_translation, github_check_run_name: 'Tests')
      end
    end

    trait :build do
      after(:create) do |ci_job|
        ci_job.parent_stage.update(name: 'Build')
        create(:bamboo_stage_translation, github_check_run_name: 'Build')
      end
    end

    trait :test do
      after(:create) do |ci_job|
        ci_job.parent_stage.update(name: 'TopoTests Ubuntu')
        create(:bamboo_stage_translation, github_check_run_name: 'TopoTests Ubuntu')
      end
    end

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

    factory :ci_job_build, traits: %i[build_stage]
  end
end
