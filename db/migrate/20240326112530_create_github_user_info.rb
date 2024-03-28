#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240326112530_create_github_user_info.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateGithubUserInfo < ActiveRecord::Migration[6.0]
  def change
    create_table :github_users do |t|
      t.string :github_login
      t.string :github_username
      t.string :github_email
      t.integer :github_id
      t.string :github_organization
      t.string :github_type
      t.string :organization_name
      t.string :organization_url

      t.timestamps
    end
  end
end
