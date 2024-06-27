#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240417094603_change_check_suite_cancelled_by_id.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class ChangeCheckSuiteCancelledById < ActiveRecord::Migration[6.0]
  def change
    change_table :check_suites do |t|
      t.references :cancelled_previous_check_suite, foreign_key: { to_table: :check_suites }
    end
  end
end
