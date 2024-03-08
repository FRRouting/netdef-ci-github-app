#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231214093515_create_feature.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreateFeature < ActiveRecord::Migration[6.0]
  def change
    create_table :features do |t|
      t.boolean :rerun, null: false, default: true
      t.integer :max_rerun_per_pull_request, null: false, default: 3
      t.timestamps

      t.references :group, index: true, foreign_key: true
    end

    community = Group.find_by(name: 'Community', anonymous: true)
    community = Group.create(name: 'Community', anonymous: true) if community.nil?

    Feature.create(group: community, rerun: true, max_rerun_per_pull_request: 3)
  end
end
