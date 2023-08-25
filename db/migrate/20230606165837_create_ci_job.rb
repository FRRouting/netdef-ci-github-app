#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230606165837_create_ci_job.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateCiJob < ActiveRecord::Migration[6.0]
  def change
    create_table :ci_jobs do |t|
      t.string :name, null: false
      t.integer :status, null: false, default: 0
      t.string :job_ref
      t.string :check_ref
      t.timestamps

      t.references :check_suite, index: true, foreign_key: true
    end
  end
end
