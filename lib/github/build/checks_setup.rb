#  SPDX-License-Identifier: BSD-2-Clause
#
#  checks_setup.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'action'

module Github
  module Build
    # GitHub side of a new execution, run after the Bamboo plan has started.
    #
    # It never creates a CheckSuite and never starts or stops a Bamboo build, so it is
    # safe to run again (resume: true) when an earlier attempt failed half way.
    class ChecksSetup
      def initialize(check_suite, plan, previous_check_suite: nil, github_user_id: nil, resume: false)
        @check_suite = check_suite
        @plan = plan
        @previous_check_suite = previous_check_suite
        @github_user_id = github_user_id
        @resume = resume
        @logger = GithubLogger.instance.create('github_app.log', Logger::INFO)
      end

      def run
        @github = Github::Check.new(@check_suite)

        # Even when superseded: the newer execution only cancels this suite's checks, not the ones before it.
        cancel_previous_checks

        return [200, 'Superseded by a newer execution'] if @resume and superseded?

        notify_execution_started unless @resume
        Github::UserInfo.new(@github_user_id, check_suite: @check_suite) unless @github_user_id.nil?

        create_summary
      end

      private

      # Marks the queued / running stages and jobs of the stopped execution as cancelled.
      # Only touches what is still open, so calling it again is harmless.
      def cancel_previous_checks
        return if @previous_check_suite.nil?

        @previous_check_suite.ci_jobs.where(status: %w[queued in_progress]).each { |job| job.cancelled(@github) }

        save_stopped_in_stage

        @previous_check_suite.stages.where(status: %w[queued in_progress]).each { |stage| stage.cancelled(@github) }
      end

      def create_summary
        jobs = BambooCi::RunningPlan.fetch(@check_suite.bamboo_ci_ref)

        return [422, 'Failed to fetch RunningPlan'] if jobs.nil? or jobs.empty?

        Github::Build::Action.new(@check_suite, @github, jobs, @plan.name).create_summary(resume: @resume)

        stop_execution_message unless @previous_check_suite.nil?

        [200, 'Pull Request created']
      end

      def save_stopped_in_stage
        stage = @previous_check_suite.stages.where(status: :in_progress).last

        @previous_check_suite.update(stopped_in_stage: stage) unless stage.nil?
      end

      def superseded?
        CheckSuite
          .where(pull_request_id: @check_suite.pull_request_id, plan_id: @check_suite.plan_id)
          .where.not(bamboo_ci_ref: nil)
          .where('id > ?', @check_suite.id)
          .exists?
      end

      # Notifications are best effort: a failure here must not reschedule the GitHub setup.
      def notify_execution_started
        SlackBot.instance.execution_started_notification(@check_suite)
      rescue StandardError => e
        @logger.error("[#{self.class}] Slack notification failed for CheckSuite #{@check_suite.id}: " \
                      "#{e.class}: #{e.message}")
      end

      def stop_execution_message
        return if @check_suite.cancelled_previous_check_suite_id == @previous_check_suite.id

        @check_suite.update(cancelled_previous_check_suite_id: @previous_check_suite.id)
        BambooCi::StopPlan.comment(@previous_check_suite, @check_suite)
      end
    end
  end
end
