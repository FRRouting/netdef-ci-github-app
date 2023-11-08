#  SPDX-License-Identifier: BSD-2-Clause
#
#  action.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    class Action
      BUILD_STAGE = 'Build Stage'
      TESTS_STAGE = 'Tests Stage'
      SUMMARY = [BUILD_STAGE, TESTS_STAGE].freeze

      def initialize(check_suite, github, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @loggers = []

        %w[github_app.log github_build_action.log].each do |filename|
          logger_app = Logger.new(filename, 1, 1_024_000)
          logger_app.level = logger_level

          @loggers << logger_app
        end
      end

      def create_summary
        SUMMARY.each do |name|
          ci_job = CiJob.find_by(name: name, check_suite: @check_suite)

          logger(Logger::INFO, "STAGE #{name} #{ci_job.inspect}")

          ci_job = CiJob.create(check_suite: @check_suite, name: name, job_ref: name, stage: true) if ci_job.nil?

          unless ci_job.persisted?
            logger(Logger::ERROR, "Failed to created: #{ci_job.inspect} -> #{ci_job.errors.inspect}")

            next
          end

          logger(Logger::INFO, ">>> Enqueued #{ci_job.inspect}")

          ci_job.enqueue(@github)
        end
      end

      def create_jobs(jobs, rerun: false)
        jobs.each do |job|
          ci_job = CiJob.create(check_suite: @check_suite, name: job[:name], job_ref: job[:job_ref])

          next unless ci_job.persisted?

          if rerun
            url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
            ci_job.enqueue(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
          else
            ci_job.create_check_run
          end

          next unless ci_job.checkout_code?

          url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
          ci_job.in_progress(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
        end
      end

      private

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
