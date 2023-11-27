#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'action'

module Github
  module Build
    class Retry < Action
      def initialize(check_suite, github, logger_level: Logger::INFO)
        super(check_suite, github)

        @loggers = []

        %w[github_app.log github_build_retry.log].each do |filename|
          logger_app = Logger.new(filename, 1, 1_024_000)
          logger_app.level = logger_level

          @loggers << logger_app
        end
      end

      def enqueued_stages
        @check_suite.ci_jobs.stages.where.not(status: :success).each do |ci_job|
          logger(Logger::WARN, "Enqueue stages: #{ci_job.inspect}")

          next if ci_job.success? or ci_job.checkout_code?

          ci_job.enqueue(@github, initial_output(ci_job))
          ci_job.update(retry: ci_job.retry + 1)
        end
      end

      def enqueued_failure_tests
        @check_suite.ci_jobs.skip_stages.where.not(status: :success).each do |ci_job|
          next if ci_job.checkout_code?

          logger(Logger::WARN, "Enqueue CiJob: #{ci_job.inspect}")
          ci_job.enqueue(@github)
          ci_job.update(retry: ci_job.retry + 1)

          logger(Logger::WARN, "Stopping Job: #{ci_job.job_ref}")
          BambooCi::StopPlan.stop(ci_job.job_ref)
        end
      end
    end
  end
end
