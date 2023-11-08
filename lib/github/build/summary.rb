#  SPDX-License-Identifier: BSD-2-Clause
#
#  summary.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../github/check'

module Github
  module Build
    class Summary
      def initialize(job, status, logger_level: Logger::INFO)
        @job = job
        @status = status
        @check_suite = @job.reload.check_suite
        @github = Github::Check.new(@check_suite)
        @loggers = []

        %w[github_app.log github_build_summary.log].each do |filename|
          logger_app = Logger.new(filename, 1, 1_024_000)
          logger_app.level = logger_level

          @loggers << logger_app
        end
      end

      def build_summary(name)
        stage = @check_suite.ci_jobs.find_by(name: name)

        return if stage.nil?

        update_summary(stage, name)
        finished_summary(stage, @check_suite)
        missing_stage(@check_suite)
      end

      def missing_stage(check_suite)
        name = nil
        name = Github::Build::Action::BUILD_STAGE if check_suite.build_stage_finished?
        name = Github::Build::Action::TESTS_STAGE if check_suite.finished?

        stage = check_suite.ci_jobs.find_by(name: name)

        return if stage.nil? or stage.failure?

        stage.success(@github)
      end

      def finished_summary(stage, check_suite)
        logger(Logger::INFO, "Finished stage: #{stage.inspect}, CiJob status: #{@status}")
        return if @status.match? 'in_progress'
        return if stage.failure?

        finished_build_summary(stage, check_suite)
        finished_tests_summary(stage, check_suite)
      end

      def finished_build_summary(stage, check_suite)
        return unless stage.build?
        return unless check_suite.build_stage_finished?

        stage.success(@github)
      end

      def finished_tests_summary(stage, check_suite)
        return unless stage.test?
        return unless check_suite.finished?

        stage.success(@github)
      end

      def update_summary(stage, name)
        return unless %w[failure in_progress].include? @status

        logger(Logger::INFO, "Updating summary status -> @status: #{@status}")

        output = { title: "#{name} summary", summary: summary_failures_message(name) }
        stage.in_progress(@github, output) if stage.queued? and @status.match? 'in_progress'

        return unless @status.match? 'failure'

        stage.failure(@github, output)
      end

      def summary_failures_message(name)
        filter = Github::Build::Action::BUILD_STAGE.include?(name) ? '.* (B|b)uild' : '(TopoTest|Check|Static)'

        @check_suite.ci_jobs.skip_checkout_code.filter_by(filter).where(status: :failure).map do |job|
          generate_message(name, job)
        end.join("\n")
      end

      private

      def generate_message(name, job)
        failures = name.downcase.match?('build') ? '' : tests_message(job)

        "- #{job.name} #{job.status} -> https://ci1.netdef.org/browse/#{job.job_ref}\n#{failures}"
      end

      def tests_message(job)
        job.topotest_failures.map do |failure|
          "\t- #{failure.test_suite} #{failure.test_case} -> ```#{failure.message}```"
        end
      end

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
