#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230607074545_create_plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreatePlan < ActiveRecord::Migration[6.0]
  def change
    create_table :plans do |t|
      t.string :bamboo_ci_plan_name, null: false
      t.string :github_repo_name, null: false, default: 0
      t.timestamps

      t.references :check_suite, index: true, foreign_key: true
    end
  end
end
