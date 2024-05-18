#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240408152636_add_check_suite_cancelled_in_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCheckSuiteCancelledInStage < ActiveRecord::Migration[6.0]
  def change
    add_reference :stages, :cancelled_at_stage, foreign_key: { to_table: :check_suites }
  end
end
