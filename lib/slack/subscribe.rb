#  SPDX-License-Identifier: BSD-2-Clause
#
#  subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Slack
  class Subscribe
    def initialize(payload)
      @payload = payload
    end

    def subscribe
      pr = PullRequest.find_by(github_pr_id: @payload['pr_id'])

      return 'PR not found' if pr.nil?

      subscription = PullRequestSubscribe.find_by(pull_request: pr, slack_user_id: @payload['slack_user_id'])

      if subscription.nil?
        subscription =
          PullRequestSubscribe.create(pull_request: pr,
                                      slack_user_id: @payload['slack_user_id'],
                                      notification: fetch_notification)

        return subscription.persisted? ? "Subscription created #{subscription.id}" : 'Failed to subscribe'
      end

      subscription.update(notification: fetch_notification)

      "Subscription updated #{subscription.id}"
    end

    private

    def fetch_notification
      return 'error' if @payload['notification'].downcase.match? 'error'

      nil
    end
  end
end
