#  SPDX-License-Identifier: BSD-2-Clause
#
#  20230727094949_add_check_suite_flags.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class AddCheckSuiteFlags < ActiveRecord::Migration[6.0]
  def change
    add_column :check_suites, :re_run, :boolean, default: false
    add_column :check_suites, :retry, :integer, default: 0
  end
end
