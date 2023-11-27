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
      BUILD_STAGE = 'Build'
      TESTS_STAGE = 'Tests'
      SOURCE_CODE = 'Linter'
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

        logger(Logger::INFO, "Building action to CheckSuite @#{@check_suite.inspect}")
      end

      def create_summary
        SUMMARY.each do |name|
          stage = CiJob.find_by(name: name, check_suite_id: @check_suite.id)

          logger(Logger::INFO, "STAGE #{name} #{stage.inspect} - @#{@check_suite.inspect}")

          stage = create_stage(name) if stage.nil?

          next if stage.nil? or stage.checkout_code? or stage.success?

          logger(Logger::INFO, ">>> Enqueued #{stage.inspect}")

          stage.enqueue(@github, output: initial_output(stage))
        end
      end

      def create_stage(name)
        bamboo_ci = @check_suite.bamboo_ci_ref.split('-').last

        stage =
          CiJob.create(check_suite: @check_suite, name: name, job_ref: "#{name}-#{bamboo_ci}", stage: true)

        return stage if stage.persisted?

        logger(Logger::ERROR, "Failed to created: #{stage.inspect} -> #{stage.errors.inspect}")

        nil
      end

      def create_jobs(jobs, rerun: false)
        jobs.each do |job|
          ci_job = CiJob.create(check_suite: @check_suite, name: job[:name], job_ref: job[:job_ref])

          next unless ci_job.persisted?

          if rerun
            next if ci_job.checkout_code?

            url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
            ci_job.enqueue(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
          else
            ci_job.create_check_run
          end

          next unless ci_job.checkout_code?

          ci_job.update(stage: true)
          url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
          ci_job.in_progress(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
        end
      end

      private

      def initial_output(ci_job)
        output = { title: '', summary: '' }
        url = "https://ci1.netdef.org/browse/#{ci_job.check_suite.bamboo_ci_ref}"

        output[:title] = "#{ci_job.name} summary"
        output[:summary] = "Details at [#{url}](#{url})"

        output
      end

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
