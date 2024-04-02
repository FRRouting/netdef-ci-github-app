#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_user.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

FactoryBot.define do
  factory :github_user do
    github_login { Faker::Crypto.md5 }
    github_username { Faker::Name.name }
    group { create(:group) }
  end
end
