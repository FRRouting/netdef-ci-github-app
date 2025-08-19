#   SPDX-License-Identifier: BSD-2-Clause
#
#   20250812101554_add_pull_requests_plans.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

class AddCheckSuiteMultipleBambooRef < ActiveRecord::Migration[6.0]
  def change
    create_table :bamboo_refs do |t|
      t.string :bamboo_key, null: false
      t.references :check_suite, null: false, foreign_key: true

      t.timestamps
    end

    add_index :bamboo_refs, :bamboo_key, unique: true
  end
end