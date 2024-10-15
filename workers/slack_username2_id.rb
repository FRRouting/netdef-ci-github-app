# frozen_string_literal: true

#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack_username2_id.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class SlackUsername2Id
  class << self
    def fetch_id(username, slack_name)
      @logger = GithubLogger.instance.create('slack_username_to_id.log', Logger::INFO)

      user = GithubUser.find_by(github_login: username)

      return false unless user

      id = SlackBot.instance.find_user_id_by_name(slack_name)

      @logger.info("Username: '#{username}' -> '#{id}'")

      user.slack_id = id
      user.save

      true
    end
  end
end
