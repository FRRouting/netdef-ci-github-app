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
        BambooStageTranslation.all.each do |bamboo_stage|
          next unless can_retry?(bamboo_stage)

          stage = CiJob.find_by(check_suite: @check_suite, name: bamboo_stage.github_check_run_name)

          next if stage.success?

          stage.enqueue(@github, initial_output(stage))
          stage.update(retry: stage.retry + 1)
        end
      end

      def enqueued_failure_tests
        @check_suite.ci_jobs.skip_stages.where.not(status: :success).each do |ci_job|
          next unless can_retry?(BambooStageTranslation.find_by(github_check_run_name: ci_job.parent_stage.name))

          logger(Logger::WARN, "Enqueue CiJob: #{ci_job.inspect}")
          ci_job.enqueue(@github)
          ci_job.update(retry: ci_job.retry + 1)
        end
      end

      private

      def can_retry?(bamboo_stage)
        bamboo_stage.can_retry?
      end
    end
  end
end
