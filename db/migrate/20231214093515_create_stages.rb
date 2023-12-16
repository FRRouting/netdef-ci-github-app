#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_stages.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateStages < ActiveRecord::Migration[6.0]
  def change
    create_table :stages do |t|
      t.string :name, null: false
      t.integer :status, null: false, default: 0
      t.string :check_ref
      t.timestamps

      t.references :check_suite, index: true, foreign_key: true
      t.references :bamboo_stage_translations, index: true, foreign_key: true
    end

    remove_column :ci_jobs, :stage_id
    add_reference :ci_jobs, :stage, foreign_key: true
  end
end
