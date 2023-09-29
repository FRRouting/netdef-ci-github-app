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
      def initialize(payload, logger_level: Logger::INFO)
        super(payload, logger_level: logger_level)

        logger_class = Logger.new('github_rerun_command.log', 0, 1_024_000)
        logger_class.level = logger_level

        @logger_manager << logger_class
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?

        logger(Logger::DEBUG, ">>> Github::ReRun::Command - payload: #{@payload.inspect}")

        check_suite = fetch_check_suite

        return [404, 'Failed to fetch a check suite'] if check_suite.nil?

        @github_check = Github::Check.new(check_suite)
        stop_previous_execution
        bamboo_plan = start_new_execution(check_suite)
        ci_jobs(check_suite, bamboo_plan)

        [201, 'Starting re-run (command)']
      end

      private

      def fetch_check_suite
        CheckSuite
          .joins(:pull_request)
          .where(commit_sha_ref: commit_sha, pull_request: { repository: repo, github_pr_id: pr_id })
          .last
      end
    end
  end
end
