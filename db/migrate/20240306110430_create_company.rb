#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_company.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateCompany < ActiveRecord::Migration[6.0]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :contact, null: false
      t.timestamps
    end
  end
end
