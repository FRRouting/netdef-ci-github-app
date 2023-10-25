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
      message = ''
      PullRequestSubscribe.where(slack_user_id: payload['slack_user_id']).each do |subscribe|
        message += "- #{subscribe.rule} #{subscribe.target} #{subscribe.notification}\n"
      end

      message
    end
  end
end
