#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231023090822_create_pull_request_subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreatePullRequestSubscribe < ActiveRecord::Migration[6.0]
  def change
    create_table :pull_request_subscribes do |t|
      t.string :slack_user_id, null: false
      t.string :notification, null: true

      t.timestamps

      t.references :pull_request, index: true, foreign_key: true
    end
  end
end
