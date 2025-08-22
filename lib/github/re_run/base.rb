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
require_relative '../user_info'

module Github
  module ReRun
    class Base
      def initialize(payload, logger_level: Logger::INFO)
        @logger_manager = []
        @logger_level = logger_level

        @logger_manager << GithubLogger.instance.create('github_app.log', logger_level)

        @payload = payload
      end

      private

      def fetch_run_ci_by_pr(plan)
        CheckSuite
          .joins(pull_request: :plans)
          .joins(:ci_jobs)
          .where(pull_request: { plan: plan, github_pr_id: pr_id, repository: repo }, ci_jobs: { status: 1 })
          .uniq
      end

      def stop_previous_execution(plan)
        return if fetch_run_ci_by_pr(plan).empty?

        logger(Logger::INFO, 'Stopping previous execution')

        @last_check_suite = nil

        fetch_run_ci_by_pr(plan).each do |check_suite|
          stop_and_update_previous_execution(check_suite)
        end
      end

      def stop_and_update_previous_execution(check_suite)
        if @last_check_suite.nil?
          check_suite.update(stopped_in_stage: check_suite.stages.where(status: :in_progress).last)
        else
          check_suite.update(cancelled_previous_check_suite_id: @last_check_suite.id)
          @last_check_suite.update(stopped_in_stage: check_suite.stages.where(status: :in_progress).last)
        end

        cancel_previous_jobs(check_suite)

        @last_check_suite = check_suite

        BambooCi::StopPlan.build(check_suite.bamboo_ci_ref)
      end

      def cancel_previous_jobs(check_suite)
        check_suite.ci_jobs.not_skipped.each do |ci_job|
          ci_job.cancelled(@github_check)
        end
      end

      def create_ci_jobs(check_suite, plan_name)
        jobs = BambooCi::RunningPlan.fetch(check_suite.bamboo_ci_ref)

        action = Github::Build::Action.new(check_suite, @github_check, jobs, plan_name)
        action.create_summary(rerun: true)
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

      def start_new_execution(check_suite, plan)
        cleanup(check_suite)

        bamboo_plan_run = BambooCi::PlanRun.new(check_suite, plan, logger_level: @logger_level)
        bamboo_plan_run.ci_variables = ci_vars
        bamboo_plan_run.start_plan

        audit_retry =
          AuditRetry.create(check_suite: check_suite,
                            github_username: @payload.dig('sender', 'login'),
                            github_id: @payload.dig('sender', 'id'),
                            github_type: @payload.dig('sender', 'type'),
                            retry_type: 'full')

        Github::UserInfo.new(@payload.dig('sender', 'id'), check_suite: check_suite, audit_retry: audit_retry)
      end

      def ci_vars
        ci_vars = []
        ci_vars << { value: @github_check.signature, name: 'signature_secret' }

        ci_vars
      end

      def ci_jobs(check_suite, plan)
        SlackBot.instance.execution_started_notification(check_suite)

        check_suite.update(cancelled_previous_check_suite: @last_check_suite)

        create_ci_jobs(check_suite, plan.name)

        update_unavailable_jobs(check_suite)
      end

      def update_unavailable_jobs(check_suite)
        CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref).each do |cs|
          Github::Build::UnavailableJobs.new(cs).update(new_check_suite: check_suite)
        end
      end

      def cleanup(check_suite)
        check_suite.pull_request.check_suites.each do |suite|
          Delayed::Job.where('handler LIKE ?', "%method_name: :timeout\nargs:\n- #{suite.id}%")
        end
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
