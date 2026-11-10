#   SPDX-License-Identifier: BSD-2-Clause
#
#   checks_setup.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2026 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

module Github
  module Build
    # Creates the GitHub Checks (stages, CI jobs, timeout worker) for a CheckSuite whose
    # Bamboo plan is already running. It never creates a CheckSuite and never starts or
    # stops a Bamboo plan, so Delayed Job may safely run it more than once.
    class ChecksSetup
      def initialize(check_suite, plan, github_check: nil, last_check_suite: nil, resume: false)
        @check_suite = check_suite
        @plan = plan
        @github_check = github_check || Github::Check.new(check_suite)
        @last_check_suite = last_check_suite
        @resume = resume
        @logger = GithubLogger.instance.create('github_app.log', Logger::INFO)
      end

      def run
        return [200, 'CheckSuite superseded'] if @resume and superseded?

        jobs = BambooCi::RunningPlan.fetch(@check_suite.bamboo_ci_ref)

        return [422, 'Failed to fetch RunningPlan'] if jobs.nil? or jobs.empty?

        Github::Build::Action.new(@check_suite, @github_check, pending_jobs(jobs), @plan.name).create_summary

        stop_execution_message unless @last_check_suite.nil?

        [200, 'Pull Request created']
      end

      private

      # A newer push already replaced this CheckSuite (and stopped its Bamboo plan).
      def superseded?
        newest = CheckSuite.where(pull_request: @check_suite.pull_request, plan: @plan).last

        return false if newest.nil? or newest.id == @check_suite.id

        @logger.info "ChecksSetup: CheckSuite #{@check_suite.id} superseded by #{newest.id} - skipping"
        true
      end

      # On resume, a previous attempt may already have created some CI jobs.
      def pending_jobs(jobs)
        return jobs unless @resume

        existing = @check_suite.ci_jobs.pluck(:job_ref)
        jobs.reject { |job| existing.include?(job[:job_ref]) }
      end

      def stop_execution_message
        @check_suite.update(cancelled_previous_check_suite_id: @last_check_suite.id)
        BambooCi::StopPlan.comment(@last_check_suite, @check_suite)
      end
    end
  end
end
