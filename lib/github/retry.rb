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

module Github
  class Retry
    def initialize(payload, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = payload
    end

    def start
      return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?

      job = CiJob.find_by_check_ref(@payload.dig('check_run', 'id'))

      return [304, 'Already enqueued this execution'] if job.queued? or job.in_progress?

      @logger.debug "Running Job #{job.inspect}"

      check_suite = job.check_suite

      check_suite.update(retry: check_suite.retry + 1)

      create_ci_jobs(check_suite)

      BambooCi::Retry.restart(check_suite.bamboo_ci_ref)

      [200, 'Retrying failure jobs']
    end

    private

    def create_ci_jobs(check_suite)
      github_check = Github::Check.new(check_suite)

      check_suite.ci_jobs.where.not(status: :success).each do |ci_job|
        ci_job.enqueue(github_check)
        ci_job.update(retry: ci_job.retry + 1)

        @logger.warn "Stopping Job: #{ci_job.job_ref}"
        BambooCi::StopPlan.stop(ci_job.job_ref)
      end
    end

    def can_rerun?(check_suite)
      failure = check_suite.reload.ci_jobs.where(status: :failure).count

      @logger.info ">> #{failure}"

      !failure.positive?
    end
  end
end
