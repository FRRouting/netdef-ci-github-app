#  SPDX-License-Identifier: BSD-2-Clause
#
#  202404130601_change_check_suite_stopped_in_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class ChangeCheckSuiteStoppedInStage < ActiveRecord::Migration[6.0]
  def change
    if ActiveRecord::Base.connection.column_exists?(:stages, :cancelled_at_stage_id)
      remove_column :stages, :cancelled_at_stage_id
    end

    if ActiveRecord::Base.connection.column_exists?(:check_suites, :cancelled_in_stage_id)
      remove_column :check_suites, :cancelled_in_stage_id
    end

    if ActiveRecord::Base.connection.column_exists?(:check_suites, :cancelled_previous_check_suite_id)
      remove_column :check_suites, :cancelled_previous_check_suite_id
    end

    change_table :check_suites do |t|
      t.references :stopped_in_stage, foreign_key: { to_table: :stages }
      t.references :cancelled_previous_check_suite, foreign_key: { to_table: :check_suites }
    end
  end
end
