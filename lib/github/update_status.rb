#  SPDX-License-Identifier: BSD-2-Clause
#
#  update_status.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../../lib/bamboo_ci/result'
require_relative '../slack_bot/slack_bot'
require_relative 'build/summary'

module Github
  class UpdateStatus
    def initialize(payload)
      @status = payload['status']
      @logger = Logger.new('github_update_status.log')

      @output =
        if payload.dig('output', 'title').nil? and payload.dig('output', 'summary').nil?
          {}
        else
          { title: payload.dig('output', 'title'), summary: payload.dig('output', 'summary') }
        end

      @job = CiJob.find_by(job_ref: payload['bamboo_ref'])
      @check_suite = @job&.check_suite
      @failures = payload['failures']
    end

    def update
      return [404, 'CI JOB not found'] if @job.nil?
      return [304, 'Not Modified'] if @job.queued? and @status != 'in_progress' and @job.name != 'Checkout Code'
      return [304, 'Not Modified'] if @job.in_progress? and !%w[success failure].include? @status

      @github_check = Github::Check.new(@job.check_suite)

      update_status

      skipping_jobs

      [200, 'Success']
    end

    private

    def failures_stats
      @failures.each do |failure|
        TopotestFailure.create(ci_job: @job,
                               test_suite: failure['suite'],
                               test_case: failure['case'],
                               message: failure['message'],
                               execution_time: failure['execution_time'])
      end
    end

    def update_status
      case @status
      when 'in_progress'
        @job.in_progress(@github_check, @output)
      when 'success'
        @job.success(@github_check, @output)
        slack_notify_success
      else
        failure
        slack_notify_failure
      end

      summary = Github::Build::Summary.new(@job)
      summary.build_summary(Github::Build::Action::BUILD_STAGE) if @job.build?
      summary.build_summary(Github::Build::Action::TESTS_STAGE) if @job.test?

      finished_execution?
    end

    def finished_execution?
      return false unless current_execution?
      return false unless @check_suite.finished?

      @logger.info ">>> @check_suite#{@check_suite.inspect} -> finished? #{@check_suite.finished?}"
      @logger.info @check_suite.ci_jobs.last.inspect

      SlackBot.instance.execution_finished_notification(@check_suite)
    end

    def fetch_last_check_suite
      pull_request = @check_suite.pull_request
      pull_request.check_suites.all.order(:created_at).last
    end

    def current_execution?
      pull_request = @check_suite.pull_request
      last_check_suite = pull_request.check_suites.reload.all.order(:created_at).last

      @logger.info "last_check_suite: #{last_check_suite.inspect}"
      @logger.info "@check_suite: #{@check_suite.inspect}"

      @check_suite.id == last_check_suite.id
    end

    # The unable2find string must match the phrase defined in the ci-files repository file
    # github_checks/hook_api.py method __topotest_title_summary
    def failure
      unable2find = "There was some test that failed, but I couldn't find the log."
      fetch_and_update_failures(unable2find) if !@output.empty? and @output[:summary].match?(unable2find)

      @job.failure(@github_check, @output)
      failures_stats if @job.name.downcase.match? 'topotest' and @failures.is_a? Array
    end

    def fetch_and_update_failures(to_be_replaced)
      output = BambooCi::Result.fetch(@job.job_ref)
      return if output.nil? or output.empty?

      @output[:summary] = @output[:summary].sub(to_be_replaced, fetch_failures(output))[0..65_535]
    end

    def fetch_failures(output)
      buffer = ''
      output.dig('testResults', 'failedTests', 'testResult').each do |test_result|
        message = ''
        test_result.dig('errors', 'error').each do |error|
          message += error['message']
          buffer += message
        end

        @failures << {
          'suite' => test_result['className'],
          'case' => test_result['methodName'],
          'message' => message,
          'execution_time' => test_result['durationInSeconds']
        }
      end

      buffer
    end

    def skipping_jobs
      return if @job.checkout_code? or @job.test?
      return unless @job.build? and @status == 'failure'

      @job.check_suite.ci_jobs.where(status: :queued).each do |job|
        job.cancelled(@github_check)
      end
    end

    def slack_notify_success
      return unless current_execution?

      fetch_subscriptions(%w[all pass]).each do |subscription|
        SlackBot.instance.notify_success(@job, subscription)
      end
    end

    def slack_notify_failure
      return unless current_execution?

      fetch_subscriptions(%w[all errors]).each do |subscription|
        SlackBot.instance.notify_errors(@job, subscription)
      end
    end

    def fetch_subscriptions(notification)
      pull_request = @job.check_suite.pull_request

      PullRequestSubscription
        .where(target: [pull_request.github_pr_id, pull_request.author], notification: notification)
        .uniq(&:slack_user_id)
    end
  end
end
