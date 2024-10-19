#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240617121935_create_delayed_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddGithubUserSlackId < ActiveRecord::Migration[6.0]
  def change
    add_column :github_users, :slack_username, :string
    add_column :github_users, :slack_id, :string
  end
end
