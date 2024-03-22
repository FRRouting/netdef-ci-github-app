#  SPDX-License-Identifier: BSD-2-Clause
#
#  group.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :group do
    name { Faker::App.name }
    public { true }
    feature { create(:feature) }
  end
end
