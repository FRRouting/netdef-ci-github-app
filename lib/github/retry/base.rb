#  SPDX-License-Identifier: BSD-2-Clause
#
#  base.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

#  SPDX-License-Identifier: BSD-2-Clause
#
#  base.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative '../../../database_loader'

require_relative '../../bamboo_ci/retry'
require_relative '../../bamboo_ci/stop_plan'
require_relative '../../github/build/retry'

require_relative '../check'
require_relative '../build/unavailable_jobs'

module Github
  module Retry
    class Base
      def initialize(payload)
        @payload = payload
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?

        logger(Logger::DEBUG, "Running stage #{@stage.inspect}")

        return [404, 'Stage not found'] if @stage.nil?
        return [406, 'Already enqueued this execution'] if @stage.queued? or @stage.in_progress?

        @check_suite = @stage.check_suite

        return enqueued if @check_suite.in_progress?

        normal_flow
      end

      private

      def github_reaction_feedback(comment_id)
        return if comment_id.nil?

        github_check = Github::Check.new(@stage.check_suite)
        github_check.comment_reaction_thumb_up(@stage.check_suite.pull_request.repository, comment_id)
      end

      def github_reaction_feedback_down(comment_id)
        return if comment_id.nil?
        return if @stage.check_suite.nil?

        github_check = Github::Check.new(@stage.check_suite)
        github_check.comment_reaction_thumb_down(@stage.check_suite.pull_request.repository, comment_id)
      end

      def normal_flow
        @check_suite.update(retry: @check_suite.retry + 1)

        create_ci_jobs(@check_suite)

        BambooCi::Retry.restart(@check_suite.bamboo_ci_ref)
        Github::Build::UnavailableJobs.new(@check_suite).update

        SlackBot.instance.execution_started_notification(@check_suite)

        github_reaction_feedback(@comment_id) if @comment_id

        [200, 'Retrying failure jobs']
      end

      def create_ci_jobs(check_suite)
        github_check = Github::Check.new(check_suite)

        audit_retry =
          AuditRetry.create(check_suite: check_suite,
                            github_username: @payload.dig('sender', 'login'),
                            github_id: @payload.dig('sender', 'id'),
                            github_type: @payload.dig('sender', 'type'),
                            retry_type: 'partial')

        Github::UserInfo.new(@payload.dig('sender', 'id'), check_suite: check_suite, audit_retry: audit_retry)

        build_retry = Github::Build::Retry.new(check_suite, github_check, audit_retry)

        build_retry.enqueued_stages
        build_retry.enqueued_failure_tests

        BambooCi::StopPlan.build(check_suite.bamboo_ci_ref)
      end

      def enqueued
        github_check = Github::Check.new(@stage.check_suite)
        previous_stage = github_check.get_check_run(@stage.check_ref)

        reason = slack_notification

        output = { title: previous_stage.dig(:output, :title).to_s, summary: previous_stage.dig(:output, :summary).to_s }

        @stage.enqueue(github_check)
        @stage.failure(github_check, output: output)

        [406, reason]
      end

      def slack_notification
        reason = SlackBot.instance.invalid_rerun_group(@stage)

        logger(Logger::WARN, ">>> #{@stage.inspect} #{reason}")

        pull_request = @stage.check_suite.pull_request

        PullRequestSubscription
          .where(target: [pull_request.github_pr_id, pull_request.author], notification: %w[all errors])
          .uniq(&:slack_user_id)
          .each { |subscription| SlackBot.instance.invalid_rerun_dm(@stage, subscription) }

        reason
      end

      def create_logger(logger_level)
        @logger_manager = []
        @logger_manager << GithubLogger.instance.create('github_app.log', logger_level)
        @logger_manager << GithubLogger.instance.create('github_retry.log', logger_level)
      end

      def logger(severity, message)
        @logger_manager.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
