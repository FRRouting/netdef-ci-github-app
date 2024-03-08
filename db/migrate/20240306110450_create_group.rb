#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_group.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateGroup < ActiveRecord::Migration[6.0]
  def change
    create_table :groups do |t|
      t.string :name, null: false
      t.boolean :anonymous, null: false, default: true
      t.timestamps
    end
  end
end
