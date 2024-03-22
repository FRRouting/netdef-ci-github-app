#  SPDX-License-Identifier: BSD-2-Clause
#
#  user.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :user do
    github_id { Faker::Crypto.md5 }
    github_username { Faker::Name.name }
    group { create(:group) }
  end
end
