#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230712075657_create_topotest_failures.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateTopotestFailures < ActiveRecord::Migration[6.0]
  def change
    create_table :topotest_failures do |t|
      t.string :test_suite, null: false
      t.string :test_case, null: false
      t.string :message, null: false
      t.integer :execution_time, null: false
      t.timestamps

      t.references :ci_job, index: true, foreign_key: true
    end
  end
end
