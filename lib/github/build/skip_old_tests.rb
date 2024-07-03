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
      def initialize(check_suite)
        @check_suite = check_suite
        @github = Github::Check.new(@check_suite)
        @stages = StageConfiguration.all.map(&:github_check_run_name)
        @logger = GithubLogger.instance.create('github_skip_old_tests.log', Logger::INFO)
      end

      def skip_old_tests
        @github
          .check_runs_for_ref(@check_suite.pull_request.repository, @check_suite.commit_sha_ref)[:check_runs]
          &.each { |check_run| skipping_old_test(check_run) }
      end

      private

      def skipping_old_test(check_run)
        return if @stages.include?(check_run[:name]) or check_run[:app][:name] != 'NetDEF CI Hook'

        @logger.info("Skipping old test suite: #{check_run[:name]}")

        message = 'Old test suite, skipping...'
        @github.create(check_run[:name])
        @github.skipped(check_run[:id], { title: "#{check_run[:name]} summary", summary: message })
      end
    end
  end
end
