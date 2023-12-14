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
    class Retry
      def initialize(check_suite, github, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @loggers = []
        @stages_config = BambooStageTranslation.all

        %w[github_app.log github_build_retry.log].each do |filename|
          logger_app = Logger.new(filename, 1, 1_024_000)
          logger_app.level = logger_level

          @loggers << logger_app
        end
      end

      def enqueued_stages
        @stages_config.each do |bamboo_stage|
          next unless bamboo_stage.can_retry?

          stage = Stage.find_by(check_suite: @check_suite, name: bamboo_stage.github_check_run_name)

          next if stage.success?

          url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
          output = { title: "#{stage.name} summary", summary: "Uninitialized stage\nDetails at [#{url}](#{url})" }

          stage.enqueue(@github, output)
        end
      end

      def enqueued_failure_tests
        @check_suite.ci_jobs.where.not(status: :success).each do |ci_job|
          next unless ci_job.stage.bamboo_stage_translations.can_retry?

          logger(Logger::WARN, "Enqueue CiJob: #{ci_job.inspect}")
          ci_job.enqueue(@github)
          ci_job.update(retry: ci_job.retry + 1)
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
