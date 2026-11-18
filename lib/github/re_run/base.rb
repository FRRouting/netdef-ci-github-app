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
require_relative '../duplicate_request_guard'
require_relative '../build/action'
require_relative '../build/unavailable_jobs'
require_relative '../user_info'
require_relative '../build/open_checks'

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

      def duplicated_request
        logger(Logger::WARN, ">>> Duplicated rerun request ignored for PR #{pr_id} (#{repo})")

        [202, 'Rerun already scheduled']
      end

      def fetch_plans
        @pull_request.plans.presence || Plan.where(github_repo_name: repo)
      end

      # A failed attempt frees the rerun claim, so the user can ask again right away. Once the Bamboo plan
      # has started, an error must neither free the claim nor reach Delayed Job, whose retry would start
      # a second build.
      def release_claim_on_failure
        status = yield
        Github::DuplicateRequestGuard.release_failed_rerun(@pull_request, fetch_plans) unless status.first == 201

        status
      rescue StandardError => e
        return failed_after_start(e) if @plan_status == 200

        Github::DuplicateRequestGuard.release_failed_rerun(@pull_request, fetch_plans)
        raise
      end

      def failed_after_start(error)
        logger(Logger::ERROR, ">>> Rerun failed after the Bamboo plan started: #{error.class}: #{error.message}")

        [201, 'Starting re-run (GitHub setup failed)']
      end

      def fetch_run_ci_by_pr(plan)
        CheckSuite
          .joins(pull_request: :plans)
          .joins(:ci_jobs)
          .where(pull_request: { plans: { id:  plan.id },
                                 github_pr_id: pr_id, repository: repo },
                 ci_jobs: { status: 1 })
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

      # A build Bamboo refused to stop keeps running, so its checks and its timeout worker are kept.
      def stop_and_update_previous_execution(check_suite)
        unless BambooCi::StopPlan.stop_execution(check_suite.bamboo_ci_ref)
          return logger(Logger::ERROR, ">>> Bamboo refused to stop #{check_suite.bamboo_ci_ref}")
        end

        record_stopped_execution(check_suite)
      end

      def record_stopped_execution(check_suite)
        if @last_check_suite.nil?
          check_suite.update(stopped_in_stage: check_suite.stages.where(status: :in_progress).last)
        else
          check_suite.update(cancelled_previous_check_suite_id: @last_check_suite.id)
          @last_check_suite.update(stopped_in_stage: check_suite.stages.where(status: :in_progress).last)
        end

        cancel_previous_jobs(check_suite)

        @last_check_suite = check_suite
        (@stopped_check_suites ||= []) << check_suite
      end

      # Leaves on each stopped Bamboo result a link to the execution that replaced it. Runs after the new
      # plan started, since its Bamboo reference only exists then.
      def comment_stopped_executions(check_suite)
        return if check_suite.bamboo_ci_ref.nil?

        Array(@stopped_check_suites).each do |stopped|
          next if stopped.bamboo_ci_ref.nil? or stopped.id == check_suite.id

          BambooCi::StopPlan.comment(stopped, check_suite)
        end
      end

      def cancel_previous_jobs(check_suite)
        Github::Build::OpenChecks.cancel(check_suite, @github_check)
      end

      # Raises while Bamboo lists no job of the new build yet, which reschedules the GitHub side.
      def create_ci_jobs(check_suite, plan_name)
        jobs = BambooCi::RunningPlan.fetch!(check_suite.bamboo_ci_ref)

        action = Github::Build::Action.new(check_suite, @github_check, jobs, plan_name)
        action.create_summary(rerun: true, resume: @resume)
      end

      def logger(severity, message)
        @logger_manager.each do |logger_object|
          logger_object.add(severity, message)
        end
      end

      def start_new_execution(check_suite, plan)
        cleanup(check_suite)

        PrometheusMetrics::CI_JOB_RETRIES.increment(labels: { reason: 'full' })

        bamboo_plan_run = BambooCi::PlanRun.new(check_suite, plan, logger_level: @logger_level)
        bamboo_plan_run.ci_variables = ci_vars
        @plan_status = bamboo_plan_run.start_plan
      end

      # Runs once the Bamboo plan has started. A GitHub error must not reach Delayed Job: retrying the whole
      # job would stop the build that has just started. Only the GitHub checks are rescheduled.
      def setup_github_checks(check_suite, plan)
        announce_execution(check_suite)
        create_github_checks(check_suite, plan)
      rescue StandardError => e
        logger(Logger::ERROR, ">>> GitHub checks setup failed for CheckSuite #{check_suite.id}: " \
                              "#{e.class}: #{e.message} - rescheduling")

        Github::ReRun::ChecksResume.schedule(self.class::QUEUE, @payload, check_suite, plan)
      end

      # Runs once, before anything that can fail and be resumed. Slack and the Bamboo comments are best
      # effort, so they never send the GitHub setup to the resume.
      def announce_execution(check_suite)
        check_suite.update(cancelled_previous_check_suite: @last_check_suite)
        notify_execution_started(check_suite)
        comment_stopped_executions(check_suite)
      end

      # The part ChecksResume runs again: safe to repeat.
      def create_github_checks(check_suite, plan)
        record_full_retry(check_suite) unless AuditRetry.exists?(check_suite: check_suite, retry_type: 'full')
        create_ci_jobs(check_suite, plan.name)
        update_unavailable_jobs(check_suite)
      end

      def notify_execution_started(check_suite)
        SlackBot.instance.execution_started_notification(check_suite)
      rescue StandardError => e
        logger(Logger::ERROR, ">>> Slack notification failed for CheckSuite #{check_suite.id}: " \
                              "#{e.class}: #{e.message}")
      end

      def record_full_retry(check_suite)
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

      def update_unavailable_jobs(check_suite)
        CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref).each do |cs|
          Github::Build::UnavailableJobs.new(cs).update(new_check_suite: check_suite)
        end
      end

      # Removes the timeout workers of the executions this rerun stopped. Any other suite keeps its own:
      # a build that was not stopped (only queued jobs, or refused by Bamboo) may still be running, and
      # TimeoutExecution does nothing for a suite that has already finished.
      def cleanup(check_suite)
        Array(@stopped_check_suites).each do |suite|
          next if suite.id == check_suite.id

          DelayedJobLookup.pending(method: :timeout, first_arg: suite.id).destroy_all
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
