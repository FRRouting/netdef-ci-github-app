#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_app.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../../database_loader'
require_relative '../../bamboo_ci/retry'
require_relative '../../bamboo_ci/stop_plan'
require_relative '../parsers/pull_request_commit'

require_relative '../check'
require_relative '../build/action'
require_relative '../build/unavailable_jobs'

module Github
  module ReRun
    class Base
      def initialize(payload, logger_level: Logger::INFO)
        @logger_manager = []
        @logger_level = logger_level

        logger_app = Logger.new('github_app.log', 1, 1_024_000)
        logger_app.level = logger_level

        @logger_manager << logger_app

        @payload = payload
      end

      private

      def fetch_run_ci_by_pr
        CheckSuite
          .joins(:pull_request)
          .joins(:ci_jobs)
          .where(pull_request: { github_pr_id: pr_id, repository: repo }, ci_jobs: { status: 1 })
          .uniq
      end

      def stop_previous_execution
        return if fetch_run_ci_by_pr.empty?

        logger(Logger::INFO, 'Stopping previous execution')
        logger(Logger::INFO, fetch_run_ci_by_pr.inspect)

        fetch_run_ci_by_pr.each do |check_suite|
          check_suite.ci_jobs.skip_stages.not_skipped.each do |ci_job|
            ci_job.cancelled(@github_check)
          end

          BambooCi::StopPlan.build(check_suite.bamboo_ci_ref)
        end
      end

      def create_ci_jobs(bamboo_plan, check_suite)
        jobs = BambooCi::RunningPlan.fetch(bamboo_plan.bamboo_reference)

        action = Github::Build::Action.new(check_suite, @github_check)
        action.create_summary
        action.create_jobs(jobs, rerun: true)
      end

      def fetch_plan
        plan = Plan.find_by_github_repo_name(@payload.dig('repository', 'full_name'))

        return plan.bamboo_ci_plan_name unless plan.nil?

        # Default plan
        'TESTING-FRRCRAS'
      end

      def logger(severity, message)
        @logger_manager.each do |logger_object|
          logger_object.add(severity, message)
        end
      end

      def start_new_execution(check_suite)
        bamboo_plan_run = BambooCi::PlanRun.new(check_suite, logger_level: @logger_level)
        bamboo_plan_run.ci_variables = ci_vars
        bamboo_plan_run.start_plan
        bamboo_plan_run
      end

      def ci_vars
        ci_vars = []
        ci_vars << { value: @github_check.signature, name: 'signature_secret' }

        ci_vars
      end

      def ci_jobs(check_suite, bamboo_plan)
        check_suite.update(bamboo_ci_ref: bamboo_plan.bamboo_reference, re_run: true)

        create_ci_jobs(bamboo_plan, check_suite)

        CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref).each do |cs|
          Github::Build::UnavailableJobs.new(cs).update(new_check_suite: check_suite)
        end

        SlackBot.instance.execution_started_notification(check_suite)
      end

      def action
        @payload.dig('comment', 'body')
      end

      def pr_id
        @payload.dig('issue', 'number') || @payload.dig('check_suite', 'pull_requests')&.last&.[]('number')
      end

      def repo
        @payload.dig('repository', 'full_name')
      end

      def comment_id
        @payload.dig('comment', 'id')
      end

      def commit_sha
        @payload.dig('check_suite', 'head_sha')
      end
    end
  end
end
