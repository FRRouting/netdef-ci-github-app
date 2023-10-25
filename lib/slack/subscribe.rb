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
    def call(payload)
      @payload = payload

      fetch_subscription
      unsubscribe?
      subscribe
    end

    private

    def subscribe
      if @subscription.nil?
        @subscription =
          PullRequestSubscribe.create(rule: @payload['rule'],
                                      target: @payload['target'],
                                      slack_user_id: @payload['slack_user_id'],
                                      notification: @payload['notification'])

        return @subscription.persisted? ? "Subscription created #{@subscription.id}" : 'Failed to subscribe'
      end

      @subscription.update(notification: @payload['notification'])

      "Subscription updated #{@subscription.id}"
    end

    def fetch_subscription
      @subscription = PullRequestSubscribe.find_by(slack_user_id: @payload['slack_user_id'],
                                                   rule: @payload['rule'],
                                                   target: @payload['target'])
    end

    def unsubscribe?
      return false if @subscription.nil? or !@payload['notification'].match? 'off'

      @subscription&.destroy
    end
  end
end
