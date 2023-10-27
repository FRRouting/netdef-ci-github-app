#  SPDX-License-Identifier: BSD-2-Clause
#
#  settings.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Slack
  class Settings
    def call(payload)
      message = []
      PullRequestSubscription.where(slack_user_id: payload['slack_user_id']).each do |subscribe|
        message << [subscribe.rule, subscribe.target, subscribe.notification]
      end

      message.empty? ? "You don't have any subscription" : to_table(message)
    end

    private

    def to_table(messages)
      table =  "|     Type     |           Target          | Notification Level |\n"
      table += "| ------------ | ------------------------- | ------------------ |\n"

      messages.each do |message|
        target = message[1] + calc_padding(message[1], 25)
        notification = message[2] + calc_padding(message[2], 18)

        table += "| #{message[0].match?('notify') ? 'Pull Request' : 'GitHub User '} | #{target} | #{notification} |\n"
      end

      "```#{table}```"
    end

    def calc_padding(str, max_size)
      ' ' * (max_size - str.size)
    end
  end
end
