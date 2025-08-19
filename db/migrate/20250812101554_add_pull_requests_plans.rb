#   SPDX-License-Identifier: BSD-2-Clause
#
#   20250812101554_add_pull_requests_plans.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

class AddPullRequestsPlans < ActiveRecord::Migration[6.0]
  def change
    add_reference :plans, :pull_request, foreign_key: true
    add_column :plans, :name, :string, null: false, default: ''
  end
end