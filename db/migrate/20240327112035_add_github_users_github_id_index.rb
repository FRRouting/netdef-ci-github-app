#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240327112035_add_github_users_github_id_index.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddGithubUsersGithubIdIndex < ActiveRecord::Migration[6.0]
  def change
    add_index :github_users, :github_id, name: 'index_github_users_on_github_id', unique: true
  end
end
