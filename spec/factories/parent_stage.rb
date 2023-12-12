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
  factory :parent_stage do
    stage { true }
    name { Faker::App.name }
    status { 0 }
    job_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }

    after(:create) do |parent_stage|
      create(:bamboo_stage_translation,
             github_check_run_name: parent_stage.name,
             position: ParentStage.where(check_suite: parent_stage.check_suite).size)
    end

    trait :failure do
      status { :failure }
    end

    trait :success do
      status { :success }
    end

    trait :build do
      name { 'Build' }
      after(:create) do |parent_stage|
        parent_stage.bamboo_stage.update(github_check_run_name: 'Build')
      end
    end

    trait :test do
      name { 'TopoTest AMD' }
      after(:create) do |parent_stage|
        parent_stage.bamboo_stage.update(github_check_run_name: 'TopoTest AMD')
      end
    end
  end
end
