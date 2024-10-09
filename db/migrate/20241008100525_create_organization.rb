#  SPDX-License-Identifier: BSD-2-Clause
#
#  20240617121935_create_delayed_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateOrganization < ActiveRecord::Migration[6.0]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :contact_email
      t.string :contact_name
      t.string :url

      t.timestamps null: false
    end
  end
end
