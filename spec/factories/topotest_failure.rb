#  SPDX-License-Identifier: BSD-2-Clause
#
#  topotest_failure.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :topotest_failure do
    test_suite { Faker::App.name }
    test_case { Faker::App.name }
    message { Faker::Quote.famous_last_words }
    execution_time { 30 }

    ci_job
  end
end
