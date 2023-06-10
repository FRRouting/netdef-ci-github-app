# frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/re_run_job'

require_relative 'check'

module GitHub
  class ReRun
    def initialize(payload, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = payload
    end

    def start
      return [422, "Invalid payload:\n#{payload}"] if @payload.nil? or @payload.empty?

      @github_check = Github::Check.new(@payload)

      job = CiJob.find_by_check_ref(@payload.dig('check_run', 'id'))

      @logger.debug "Running Job #{job.inspect}"

      job.enqueue(@github_check)

      check_suite = job.check_suite

      BambooCi::ReRunJob.restart(job.job_ref) if can_rerun? check_suite
    end

    private

    def can_rerun?(check_suite)
      enqueued = check_suite.ci_jobs.all.size - check_suite.ci_jobs.where.not(status: %i[success]).size

      check_suite.ci_jobs.where(status: :queued).size == enqueued
    end
  end
end
