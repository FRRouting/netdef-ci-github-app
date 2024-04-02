#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240402114622_add_github_users_group.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddGithubUsersGroup < ActiveRecord::Migration[6.0]
  def change
    add_reference :github_users, :group, foreign_key: true
  end
end
