#  SPDX-License-Identifier: BSD-2-Clause
#
#  update_status.rb
#  Part of NetDEF CI System
#
#  This class handles the update of the status for a given CI job.
#  It updates the job status, logs messages, and manages delayed jobs.
#
#  Methods:
#  - initialize(payload): Initializes the UpdateStatus class with the given payload.
#  - update: Updates the status of the CI job based on the payload.
#
#  Example usage:
#    Github::UpdateStatus.new(payload).update
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
    ##
    # Initializes the UpdateStatus class with the given payload.
    #
    # @param [Hash] payload The payload containing information about the CI job.
    def initialize(payload)
      @status = payload['status']

      @reference = payload['bamboo_ref'] || 'invalid_reference'
      @job = CiJob.find_by(job_ref: payload['bamboo_ref'])
      @check_suite = @job&.check_suite
      @failures = payload['failures'] || []

      @summary = ''
      @summary = payload['output']['summary'] if payload.key? 'output'

      logger_initializer
    end

    ##
    # Updates the status of the CI job based on the payload.
    #
    # @return [Array] An array containing the status code and message.
    def update
      return job_not_found if @job.nil?
      return [304, 'Not Modified'] if @job.queued? and @status != 'in_progress' and @job.name != 'Checkout Code'
      return [304, 'Not Modified'] if @job.in_progress? and !%w[success failure].include? @status

      @github_check = Github::Check.new(@job.check_suite)

      update_status
    end

    private

    ##
    # Handles the case when the CI job is not found.
    #
    # @return [Array] An array containing the status code and message.
    def job_not_found
      logger(Logger::ERROR, "CI JOB not found: '#{@reference}'")

      [404, 'CI JOB not found']
    end

    ##
    # Records the failure statistics for the CI job.
    def failures_stats
      @failures.each do |failure|
        TopotestFailure.create(ci_job: @job,
                               test_suite: failure['suite'],
                               test_case: failure['case'],
                               message: failure['message'],
                               execution_time: failure['execution_time'])
      end
    end

    ##
    # Updates the status of the CI job.
    #
    # @return [Array] An array containing the status code and message.
    def update_status
      case @status
      when 'in_progress'
        @job.in_progress(@github_check)
      when 'success'
        @job.success(@github_check)
        @job.update_execution_time
      else
        failure
        @job.update_execution_time
        @job.summary = @summary
        @job.save
      end

      return [200, 'Success'] unless @job.check_suite.pull_request.current_execution? @job.check_suite

      insert_new_delayed_job

      [200, 'Success']
    rescue StandardError => e
      logger(Logger::ERROR, "#{e.class} #{e.message}")

      [500, 'Internal Server Error']
    end

    ##
    # Inserts a new delayed job for the CI job.
    def insert_new_delayed_job
      queue = @job.check_suite.pull_request.github_pr_id % 10

      delete_and_create_delayed_job(queue)
    end

    ##
    # Deletes existing delayed jobs and creates a new one.
    #
    # @param [Integer] queue The queue number for the delayed job.
    def delete_and_create_delayed_job(queue)
      fetch_delayed_job(queue).destroy_all

      CiJobStatus
        .delay(run_at: DELAYED_JOB_TIMER.seconds.from_now.utc, queue: queue)
        .update(@job.check_suite.id, @job.id)
    end

    ##
    # Fetches the delayed job for the given queue.
    #
    # @param [Integer] queue The queue number for the delayed job.
    # @return [ActiveRecord::Relation] The relation containing the delayed jobs.
    def fetch_delayed_job(queue)
      Delayed::Job
        .where(queue: queue)
        .where('handler LIKE ?', "%method_name: :update\nargs:\n- #{@check_suite.id}%")
    end

    ##
    # Handles the failure case for the CI job.
    # The unable2find string must match the phrase defined in the ci-files repository file
    # github_checks/hook_api.py method __topotest_title_summary
    def failure
      return if @job.nil?

      @job.failure(@github_check)
      return failures_stats if @failures.is_a? Array and !@failures.empty?

      CiJobFetchTopotestFailures
        .delay(run_at: 5.minutes.from_now.utc, queue: 'fetch_topotest_failures')
        .update(@job.id, 1)\
    end

    ##
    # Logs a message with the given severity.
    #
    # @param [Integer] severity The severity level.
    # @param [String] message The message to log.
    def logger(severity, message)
      @loggers.each do |logger_object|
        logger_object.add(severity, message)
      end
    end

    ##
    # Initializes the logger for the UpdateStatus class.
    def logger_initializer
      @loggers = []
      @loggers << GithubLogger.instance.create('github_update_status.log', Logger::INFO)
      @loggers << if @job.nil?
                    GithubLogger.instance.create(@reference, Logger::INFO)
                  else
                    GithubLogger.instance.create("pr#{@job.check_suite.pull_request.github_pr_id}.log", Logger::INFO)
                  end
    end
  end
end
