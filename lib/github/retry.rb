#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/retry'
require_relative '../bamboo_ci/stop_plan'

require_relative 'check'
require_relative 'build/unavailable_jobs'

module Github
  class Retry
    def initialize(payload, logger_level: Logger::INFO)
      create_logger(logger_level)

      @payload = payload
    end

    def start
      return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?

      job = CiJob.find_by_check_ref(@payload.dig('check_run', 'id'))

      return [404, 'Job not found'] if job.nil?
      return [406, 'Already enqueued this execution'] if job.queued? or job.in_progress?

      logger(Logger::DEBUG, "Running Job #{job.inspect}")

      check_suite = job.check_suite

      return enqueued(job) if check_suite.in_progress?

      normal_flow(check_suite)
    end

    private

    def normal_flow(check_suite)
      check_suite.update(retry: check_suite.retry + 1)

      create_ci_jobs(check_suite)

      BambooCi::Retry.restart(check_suite.bamboo_ci_ref)
      Github::Build::UnavailableJobs.new(check_suite).update

      SlackBot.instance.execution_started_notification(check_suite)

      [200, 'Retrying failure jobs']
    end

    def create_ci_jobs(check_suite)
      github_check = Github::Check.new(check_suite)

      check_suite.ci_jobs.where.not(status: :success).each do |ci_job|
        next if ci_job.checkout_code?

        ci_job.enqueue(github_check)
        ci_job.update(retry: ci_job.retry + 1)

        logger(Logger::WARN, "Stopping Job: #{ci_job.name} - #{ci_job.job_ref}")
      end

      BambooCi::StopPlan.build(check_suite.bamboo_ci_ref)
    end

    def enqueued(job)
      github_check = Github::Check.new(job.check_suite)
      previous_job = github_check.get_check_run(job.check_ref)

      reason = slack_notification(job)

      output = { title: previous_job.dig(:output, :title).to_s, summary: previous_job.dig(:output, :summary).to_s }

      job.enqueue(github_check)
      job.failure(github_check, output)

      [406, reason]
    end

    def slack_notification(job)
      reason = SlackBot.instance.invalid_rerun_group(job)

      pull_request = job.check_suite.pull_request

      PullRequestSubscription
        .where(target: [pull_request.github_pr_id, pull_request.author], notification: %w[all errors])
        .uniq(&:slack_user_id)
        .each { |subscription| SlackBot.instance.invalid_rerun_dm(job, subscription) }

      reason
    end

    def create_logger(logger_level)
      @logger_manager = []
      @logger_level = logger_level

      logger_app = Logger.new('github_app.log', 1, 1_024_000)
      logger_app.level = logger_level

      logger_class = Logger.new('github_retry.log', 0, 1_024_000)
      logger_class.level = logger_level

      @logger_manager << logger_app
      @logger_manager << logger_class
    end

    def logger(severity, message)
      @logger_manager.each do |logger_object|
        logger_object.add(severity, message)
      end
    end
  end
end
