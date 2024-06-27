#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240408141736_add_check_suite_cancelled_ref.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCheckSuiteCancelledRef < ActiveRecord::Migration[6.0]
  def change
    add_column :check_suites, :cancelled_by_id, :bigint
    add_index :check_suites, :cancelled_by_id
    add_foreign_key :check_suites, :stages, column: :cancelled_by_id
  end
end
