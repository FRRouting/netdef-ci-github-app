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
require_relative 'open_checks'

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
        # First, and best effort: nothing before it can fail, so a resume never has to send it again.
        notify_execution_started unless @resume

        # Even when superseded: the newer execution only cancels this suite's checks, not the ones before it.
        cancel_previous_checks

        return [200, 'Superseded by a newer execution'] if @resume and @check_suite.superseded?

        Github::UserInfo.new(@github_user_id, check_suite: @check_suite) unless @github_user_id.nil?

        create_summary
      end

      # Marks the queued / running stages and jobs of the stopped execution as cancelled.
      # Only touches what is still open, so calling it again is harmless. Also called on its own when
      # the new plan failed to start after the previous build was stopped.
      def cancel_previous_checks
        return if @previous_check_suite.nil?

        save_stopped_in_stage

        Github::Build::OpenChecks.cancel(@previous_check_suite, github)
      end

      private

      def github
        @github ||= Github::Check.new(@check_suite)
      end

      def create_summary
        # Raises while Bamboo lists no job yet: the GitHub setup is rescheduled (first attempt) or
        # retried by Delayed Job (resume) instead of ending without checks.
        jobs = BambooCi::RunningPlan.fetch!(@check_suite.bamboo_ci_ref)

        Github::Build::Action.new(@check_suite, github, jobs, @plan.name).create_summary(resume: @resume)

        stop_execution_message unless @previous_check_suite.nil?

        [200, 'Pull Request created']
      end

      def save_stopped_in_stage
        stage = @previous_check_suite.stages.where(status: :in_progress).last

        @previous_check_suite.update(stopped_in_stage: stage) unless stage.nil?
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
