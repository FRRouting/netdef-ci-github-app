#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240417102854_remove_check_suite_columns.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class RemoveCheckSuiteColumns < ActiveRecord::Migration[6.0]
  def change
    if ActiveRecord::Base.connection.column_exists?(:check_suites, :cancelled_by_id)
      remove_column :check_suites, :cancelled_by_id
    end

    remove_column :check_suites, :id_id if ActiveRecord::Base.connection.column_exists?(:check_suites, :id_id)
  end
end
