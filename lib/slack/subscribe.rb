#  SPDX-License-Identifier: BSD-2-Clause
#
#  subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../github/check'

module Slack
  class Subscribe
    def call(payload)
      @payload = payload

      fetch_subscription
      unsubscribe?

      return 'Invalid GitHub username' if invalid_github_user?

      return 'Unsubscribed' if @subscription.nil? and @payload['notification'].match? 'off'

      subscribe
    end

    private

    def subscribe
      if @subscription.nil?
        @subscription =
          PullRequestSubscription.create(rule: @payload['rule'],
                                         target: @payload['target'],
                                         slack_user_id: @payload['slack_user_id'],
                                         notification: @payload['notification'])

        return @subscription.persisted? ? 'Subscription created' : 'Failed to subscribe'
      end

      @subscription.update(notification: @payload['notification'])

      'Subscription updated'
    end

    def fetch_subscription
      @subscription = PullRequestSubscription.find_by(slack_user_id: @payload['slack_user_id'],
                                                      rule: @payload['rule'],
                                                      target: @payload['target'])
    end

    def unsubscribe?
      return false if @subscription.nil? or !@payload['notification'].match? 'off'

      @subscription.destroy

      @subscription = nil
    end

    # Checks if the GitHub user specified in the payload is invalid.
    #
    # This method iterates through the unique repository names and fetches the last pull request
    # for each repository. It then uses the `Github::Check` class to fetch the username associated
    # with the target specified in the payload. If the username is found, the method returns false,
    # indicating that the GitHub user is valid. If no username is found for any repository, the method
    # returns true, indicating that the GitHub user is invalid.
    #
    # @return [Boolean] true if the GitHub user is invalid, false otherwise.
    def invalid_github_user?
      return false if @payload['rule'].match? 'notify'

      PullRequest.unique_repository_names.each do |repo|
        pr = PullRequest.where(repository: repo).last
        github = Github::Check.new(pr.check_suites.last)

        user = github.fetch_username(@payload['target'])

        return false if user
      end

      true
    end
  end
end
