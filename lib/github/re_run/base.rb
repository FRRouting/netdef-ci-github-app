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

        @logger_manager << GithubLogger.instance.create('github_app.log', logger_level)

        @payload = payload
        @user = User.find_by(github_username: @payload.dig('comment', 'user', 'login'))
        create_user if @user.nil?
      end

      private

      def create_user
        github = Github::Check.new(nil)
        github_user = github.fetch_username(@payload.dig('comment', 'user', 'login'))
        github_user ||= github.fetch_username(@payload.dig('sender', 'login'))

        @user = User.find_by(github_id: github_user[:id])

        puts ">>> Github user: #{@user.inspect}"

        return if valid_user_and_payload? github_user

        @user =
          User.create(
            github_username: @payload.dig('sender', 'login'),
            github_id: github_user[:id],
            group: Group.find_by(public: true)
          )
      end

      def valid_user_and_payload?(github_user)
        !@user.nil? or @payload.nil? or @payload.empty? or github_user.nil? or github_user.empty?
      end

      def notify_error_rerun(comment_id: nil)
        @github_check = Github::Check.new(nil)

        comment_thumb_down(comment_id) unless comment_id.nil?

        logger(Logger::WARN, 'No permission to run')

        [402, 'No permission to run']
      end

      def reach_max_rerun_per_pull_request?
        max_rerun = @user.group.feature.max_rerun_per_pull_request

        return false if max_rerun.zero?

        github_check = Github::Check.new(nil)
        pull_request_info = github_check.pull_request_info(pr_id, repo)

        if max_rerun <
           CheckSuite.where(work_branch: pull_request_info.dig(:head, :ref), re_run: true).count
          return true
        end

        false
      end

      def can_rerun?
        @user.group.feature.rerun
      end

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
          check_suite.ci_jobs.not_skipped.each do |ci_job|
            ci_job.cancelled(@github_check)
          end

          BambooCi::StopPlan.build(check_suite.bamboo_ci_ref)
        end
      end

      def create_ci_jobs(bamboo_plan, check_suite)
        jobs = BambooCi::RunningPlan.fetch(bamboo_plan.bamboo_reference)

        action = Github::Build::Action.new(check_suite, @github_check, jobs)
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

      def start_new_execution(check_suite)
        bamboo_plan_run = BambooCi::PlanRun.new(check_suite, logger_level: @logger_level)
        bamboo_plan_run.ci_variables = ci_vars
        bamboo_plan_run.start_plan

        AuditRetry.create(check_suite: check_suite,
                          github_username: @payload.dig('sender', 'login'),
                          github_id: @payload.dig('sender', 'id'),
                          github_type: @payload.dig('sender', 'type'),
                          retry_type: 'full')

        bamboo_plan_run
      end

      def ci_vars
        ci_vars = []
        ci_vars << { value: @github_check.signature, name: 'signature_secret' }

        ci_vars
      end

      def ci_jobs(check_suite, bamboo_plan)
        SlackBot.instance.execution_started_notification(check_suite)

        check_suite.update(bamboo_ci_ref: bamboo_plan.bamboo_reference, re_run: true)

        create_ci_jobs(bamboo_plan, check_suite)

        CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref).each do |cs|
          Github::Build::UnavailableJobs.new(cs).update(new_check_suite: check_suite)
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
