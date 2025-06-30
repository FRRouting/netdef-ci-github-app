#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_notify_watch_dog.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class GithubNotifyWatchDog
  class << self
    def run
      check_stages

      GithubNotifyWatchDog
        .delay(run_at: 1.hour.from_now.utc, queue: 'github_notify_watch_dog')
        .run
    end

    def check_stages
      Stage.where(status: :in_progress).where(updated_at: ..3.hour.ago).each do |stage|
        GitHubApp::Configuration.instance.config['notify_users_when_stage_stuck']&.each do |slack_id|
          SlackBot
            .instance
            .notify_watch_dog(slack_id,
                              "Stage #{stage.name} is stuck in progress - #{stage.check_suite.bamboo_ci_ref}")
        end
      end
    end
  end
end
