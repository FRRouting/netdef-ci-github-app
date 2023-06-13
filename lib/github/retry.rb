# frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/retry'
require_relative '../bamboo_ci/stop_plan'

require_relative 'check'

module GitHub
  class Retry
    def initialize(payload, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = payload
    end

    def start
      return [422, "Invalid payload:\n#{payload}"] if @payload.nil? or @payload.empty?

      job = CiJob.find_by_check_ref(@payload.dig('check_run', 'id'))

      return [201, 'Already enqueued this execution'] if job.queued?

      @logger.debug "Running Job #{job.inspect}"

      check_suite = job.check_suite

      check_suite.ci_jobs.where.not(status: :success).each do |ci_job|
        @github_check = Github::Check.new(check_suite)
        ci_job.enqueue(@github_check)

        @logger.warn "Stopping Job: #{ci_job.job_ref}"
        BambooCi::StopPlan.stop(ci_job.job_ref)
      end

      BambooCi::Retry.restart(check_suite.bamboo_ci_ref)
    end

    private

    def can_rerun?(check_suite)
      failure = check_suite.reload.ci_jobs.where(status: :failure).count

      @logger.info ">> #{failure}"

      !failure.positive?
    end
  end
end
