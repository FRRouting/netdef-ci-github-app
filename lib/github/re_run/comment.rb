#  SPDX-License-Identifier: BSD-2-Clause
#
#  re_run.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'base'

module Github
  module ReRun
    class Comment < Base
      TIMER = 1 # seconds

      def initialize(payload, logger_level: Logger::INFO)
        super(payload, logger_level: logger_level)

        @logger_manager << GithubLogger.instance.create('github_rerun_comment.log', logger_level)
        @logger_manager << Logger.new($stdout)
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?
        return [404, 'Action not found'] unless action?

        fetch_pull_request

        confirm_and_start
      end

      private

      def confirm_and_start
        return [404, 'Pull Request not found'] if @pull_request.nil?
        return [404, 'Can not rerun a new PullRequest'] if @pull_request.check_suites.empty?

        github_reaction_feedback(comment_id)

        @pull_request.plans.each do |plan|
          CreateExecutionByComment
            .delay(run_at: TIMER.seconds.from_now.utc, queue: 'create_execution_by_comment')
            .create(@pull_request.id, @payload, plan)
        end

        [200, 'Scheduled Plan Runs']
      end

      def github_reaction_feedback(comment_id)
        return if comment_id.nil?

        github_check = Github::Check.new(@pull_request.check_suites.last)

        github_check.comment_reaction_thumb_up(repo, comment_id)
      end

      def fetch_pull_request
        @pull_request = PullRequest.find_by(github_pr_id: pr_id)
      end

      def action?
        action.to_s.downcase.match? 'ci:rerun' and @payload['action'] == 'created'
      end
    end
  end
end
