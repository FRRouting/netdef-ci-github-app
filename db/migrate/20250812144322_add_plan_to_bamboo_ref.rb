#   SPDX-License-Identifier: BSD-2-Clause
#
#   20250812144322_add_plan_to_bamboo_ref.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

class AddPlanToBambooRef < ActiveRecord::Migration[6.0]
  def change
    add_reference :bamboo_refs, :plan, null: false, foreign_key: true
  end
end
