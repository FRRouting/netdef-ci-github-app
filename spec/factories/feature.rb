#  SPDX-License-Identifier: BSD-2-Clause
#
#  feature.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :feature do
    rerun { true }
    max_rerun_per_pull_request { 3 }
  end
end
