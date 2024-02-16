#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_stages.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateAuditStatus < ActiveRecord::Migration[6.0]
  def change
    create_table :audit_statuses do |t|
      t.integer :status, null: false, default: 0
      t.string :agent
      t.datetime :created_at, null: false, precision: 6

      t.references :auditable, polymorphic: true, index: true, null: false
    end
  end
end
