#   SPDX-License-Identifier: BSD-2-Clause
#
#   20261109120000_add_duplicate_request_guards.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2026 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

class AddDuplicateRequestGuards < ActiveRecord::Migration[6.0]
  def change
    add_column :check_suites, :retry_requested_at, :datetime
    add_column :pull_requests, :rerun_requested_at, :datetime
  end
end
