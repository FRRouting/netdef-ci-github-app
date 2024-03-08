#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_user.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateUser < ActiveRecord::Migration[6.0]
  def change
    create_table :users do |t|
      t.string :github_id, null: false
      t.string :github_username, null: false
      t.string :email, null: true

      t.timestamps

      t.references :company, index: true, foreign_key: true
      t.references :group, index: true, foreign_key: true
    end
  end
end
