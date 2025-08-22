#   SPDX-License-Identifier: BSD-2-Clause
#
#   20250822071834_add_check_suite_plan.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

class AddCheckSuitePlan < ActiveRecord::Migration[6.0]
  def change
    add_reference :check_suites, :plan, foreign_key: true
  end
end
