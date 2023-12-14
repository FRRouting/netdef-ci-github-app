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
  end
end
