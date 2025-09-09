#  SPDX-License-Identifier: BSD-2-Clause
#
#  command.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'base'

module Github
  module ReRun
    class Command < Base
      TIMER = 1 # seconds

      def initialize(payload, logger_level: Logger::INFO)
        super(payload, logger_level: logger_level)

        @logger_manager << GithubLogger.instance.create('github_rerun_command.log', logger_level)
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?

        logger(Logger::DEBUG, ">>> Github::ReRun::Command - payload: #{@payload.inspect}")

        check_suite = fetch_check_suite

        return [404, 'Failed to fetch a check suite'] if check_suite.nil?

        @github_check = Github::Check.new(check_suite)

        check_suite.pull_request.plans.each do |plan|
          CreateExecutionByCommand
            .delay(run_at: TIMER.seconds.from_now.utc, queue: 'create_execution_by_command')
            .create(plan.id, check_suite.id)
        end

        [200, 'Scheduled Plan Runs']
      end

      private

      def create_check_suite(check_suite)
        CheckSuite.create(
          pull_request: check_suite.pull_request,
          author: check_suite.author,
          commit_sha_ref: check_suite.commit_sha_ref,
          work_branch: check_suite.work_branch,
          base_sha_ref: check_suite.base_sha_ref,
          merge_branch: check_suite.merge_branch,
          re_run: true
        )
      end

      def fetch_check_suite
        CheckSuite
          .joins(:pull_request)
          .where(commit_sha_ref: commit_sha, pull_request: { repository: repo, github_pr_id: pr_id })
          .last
      end
    end
  end
end
