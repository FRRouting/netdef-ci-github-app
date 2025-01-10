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

      @reference = payload['bamboo_ref'] || 'invalid_reference'
      @job = CiJob.find_by(job_ref: payload['bamboo_ref'])
      @check_suite = @job&.check_suite
      @failures = payload['failures'] || []

      logger_initializer
    end

    def update
      return job_not_found if @job.nil?
      return [304, 'Not Modified'] if @job.queued? and @status != 'in_progress' and @job.name != 'Checkout Code'
      return [304, 'Not Modified'] if @job.in_progress? and !%w[success failure].include? @status

      @github_check = Github::Check.new(@job.check_suite)

      update_status
    end

    private

    def job_not_found
      logger(Logger::ERROR, "CI JOB not found: '#{@reference}'")

      [404, 'CI JOB not found']
    end

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
        @job.in_progress(@github_check)
      when 'success'
        @job.success(@github_check)
        @job.update_execution_time
      else
        failure
        @job.update_execution_time
      end

      return [200, 'Success'] unless @job.check_suite.pull_request.current_execution? @job.check_suite

      insert_new_delayed_job

      [200, 'Success']
    rescue StandardError => e
      logger(Logger::ERROR, "#{e.class} #{e.message}")

      [500, 'Internal Server Error']
    end

    def insert_new_delayed_job
      queue = @job.check_suite.pull_request.github_pr_id % 10

      delete_and_create_delayed_job(queue)
    end

    def delete_and_create_delayed_job(queue)
      fetch_delayed_job.destroy_all

      CiJobStatus
        .delay(run_at: DELAYED_JOB_TIMER.seconds.from_now.utc, queue: queue)
        .update(@job.check_suite.id, @job.id)
    end

    def fetch_delayed_job
      Delayed::Job.where('handler LIKE ?', "%method_name: :update\nargs:\n- #{@job.check_suite.id}%")
    end

    # The unable2find string must match the phrase defined in the ci-files repository file
    # github_checks/hook_api.py method __topotest_title_summary
    def failure
      @job.failure(@github_check)

      return failures_stats if @failures.is_a? Array and !@failures.empty?

      CiJobFetchTopotestFailures
        .delay(run_at: 5.minutes.from_now.utc, queue: 'fetch_topotest_failures')
        .update(@job.id, 1)
    end

    def logger(severity, message)
      @loggers.each do |logger_object|
        logger_object.add(severity, message)
      end
    end

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
