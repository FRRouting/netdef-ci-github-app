#  SPDX-License-Identifier: BSD-2-Clause
#
#  skip_old_tests.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    class SkipOldTests
      attr_reader :stages

      def initialize(check_suite)
        @check_suite = check_suite
        @github = Github::Check.new(@check_suite)
        @stages = current_check_run_names
        @logger = GithubLogger.instance.create('github_skip_old_tests.log', Logger::INFO)
      end

      def skip_old_tests
        %w[queued in_progress success failure queued].each do |status|
          @github
            .check_runs_for_ref(@check_suite.pull_request.repository,
                                @check_suite.commit_sha_ref, status: status)[:check_runs]
            &.each { |check_run| skipping_old_test(check_run) }
        end
      end

      private

      # Stage check runs may carry a plan suffix (Action#stage_name), so every configured name is kept both
      # bare and with each plan of the repository: the current checks of every plan are never skipped.
      def current_check_run_names
        plan_names = Plan.where(github_repo_name: @check_suite.pull_request.repository).pluck(:name)

        StageConfiguration.pluck(:github_check_run_name).flat_map do |name|
          ["[CI] #{name}"] + plan_names.map { |plan_name| "[CI] #{name} - #{plan_name}" }
        end
      end

      def skipping_old_test(check_run)
        return if check_run[:app][:name] != 'NetDEF CI Hook' or @stages.include?(check_run[:name])

        @logger.info("Skipping old test suite: #{check_run[:name]}")

        message = 'Old test suite, skipping...'
        @github.skipped(check_run[:id], { title: "#{check_run[:name]} summary", summary: message })
      end
    end
  end
end
