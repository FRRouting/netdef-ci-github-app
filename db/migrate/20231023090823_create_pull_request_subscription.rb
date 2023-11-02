#  SPDX-License-Identifier: BSD-2-Clause
#
#  20231023090822_create_pull_request_subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CreatePullRequestSubscription < ActiveRecord::Migration[6.0]
  def change
    create_table :pull_request_subscriptions do |t|
      t.string :slack_user_id, null: false # Slack user who will receive the notification
      t.string :rule, null: false          # Rule type filter
      t.string :target, null: false        # Subscription type - PR or GitHub user
      t.string :notification, null: true   # Notification level

      t.timestamps

      t.references :pull_request, index: true, foreign_key: true
    end
  end
end
