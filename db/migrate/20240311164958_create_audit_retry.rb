#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240311164958_create_audit_retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateAuditRetry < ActiveRecord::Migration[6.0]
  def change
    create_table :audit_retries do |t|
      t.string :github_username
      t.string :github_id
      t.string :github_type
      t.string :retry_type
      t.timestamps

      t.references :check_suite, index: true, foreign_key: true
    end
  end
end
