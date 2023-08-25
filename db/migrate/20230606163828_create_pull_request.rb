#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230606163828_create_pull_request.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreatePullRequest < ActiveRecord::Migration[6.0]
  def change
    create_table :pull_requests do |t|
      t.string :author, null: false
      t.integer :github_pr_id, null: false
      t.string :branch_name, null: false
      t.string :repository, null: false
      t.string :plan

      t.timestamps
    end
  end
end
