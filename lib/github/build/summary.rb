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
require_relative '../../bamboo_ci/download'

module Github
  module Build
    class Summary
      def initialize(job, logger_level: Logger::INFO)
        @job = job.reload
        @check_suite = @job.check_suite
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
        finished_summary(stage)
        missing_stage(stage)
      end

      def missing_stage(stage)
        missing_test_stage(stage)
        missing_build_stage
      end

      def missing_test_stage(stage)
        tests_stage = @check_suite.ci_jobs.find_by(name: Github::Build::Action::TESTS_STAGE)
        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        tests_failure = {
          title: "#{Github::Build::Action::TESTS_STAGE} summary",
          summary: "Build Stage failed so it will not be possible to run the tests.\nDetails at [#{url}](#{url})."
        }

        return tests_stage.cancelled(@github, tests_failure) if stage.build? and stage.failure?
        return tests_stage.in_progress(@github) if stage.build? and stage.success?

        return unless stage.test?
        return unless @check_suite.finished?

        update_tests_stage(tests_stage)
      end

      def missing_build_stage
        build_stage = @check_suite.ci_jobs.find_by(name: Github::Build::Action::BUILD_STAGE)

        return if build_stage.nil?
        return if build_stage.success? or build_stage.failure?
        return unless @check_suite.build_stage_finished?

        url = "https://ci1.netdef.org/browse/#{build_stage.check_suite.bamboo_ci_ref}"
        failure = {
          title: "#{Github::Build::Action::BUILD_STAGE} summary",
          summary: "Build stage failure. Please check Bamboo CI.\nDetails at [#{url}](#{url})."
        }

        success = @check_suite.build_stage_success?
        logger(Logger::INFO, "missing_build_stage: #{build_stage.inspect}, success: #{success}")

        success ? build_stage.success(@github) : build_stage.failure(@github, failure)
      end

      def update_tests_stage(stage)
        success = @check_suite.ci_jobs.skip_checkout_code.where(status: %w[failure cancelled]).empty?

        output = { title: "#{stage.name} summary", summary: summary_failures_message(stage.name) }

        logger(Logger::INFO, "update_tests_stage: #{stage.inspect}, success: #{success}")

        success ? stage.success(@github) : stage.failure(@github, output)
      end

      def finished_summary(stage)
        logger(Logger::INFO, "Finished stage: #{stage.inspect}, CiJob status: #{@job.status}")
        return if @job.in_progress?

        finished_build_summary(stage)
        finished_tests_summary(stage)
      end

      def finished_build_summary(stage)
        return unless stage.build?
        return unless @check_suite.build_stage_finished?

        logger(Logger::INFO, "finished_build_summary: #{stage.inspect}. Reason Job: #{@job.inspect}")

        name = Github::Build::Action::BUILD_STAGE
        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = {
          title: "#{name} summary",
          summary: "#{summary_failures_message(name)}\nDetails at [#{url}](#{url})."
        }

        logger(Logger::DEBUG, output)

        @check_suite.build_stage_success? ? stage.success(@github) : stage.failure(@github, output)
      end

      def finished_tests_summary(stage)
        return unless stage.test?
        return unless @check_suite.finished?

        logger(Logger::INFO, "finished_tests_summary: #{stage.inspect}. Reason Job: #{@job.inspect}")

        name = Github::Build::Action::TESTS_STAGE
        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = {
          title: "#{name} summary",
          summary: "#{summary_failures_message(name)}\nDetails at [#{url}](#{url})."
        }

        @check_suite.success? ? stage.success(@github) : stage.failure(@github, output)
      end

      def update_summary(stage, name)
        return unless %w[failure in_progress].include? @job.status

        logger(Logger::INFO, "Updating summary status #{stage.inspect} -> @job.status: #{@job.status}")

        output = { title: "#{name} summary", summary: summary_failures_message(name) }
        stage.in_progress(@github, output) if stage.queued? and @job.in_progress?

        return unless @job.failure?

        logger(Logger::INFO, "(Failure) #{stage.inspect} -> @job.status: #{@job.status}")

        stage.in_progress(@github, output)
      end

      def summary_failures_message(name)
        filter = Github::Build::Action::BUILD_STAGE.include?(name) ? '.* (B|b)uild' : '(TopoTest|Check|Static)'

        @check_suite.ci_jobs.skip_checkout_code.filter_by(filter).where(status: :failure).map do |job|
          generate_message(name, job)
        end.join("\n")[0..65_535]
      end

      private

      def generate_message(name, job)
        failures = name.downcase.match?('build') ? build_message(job) : tests_message(job)

        "- #{job.name} #{job.status} -> https://ci1.netdef.org/browse/#{job.job_ref}\n#{failures}"
      end

      def tests_message(job)
        failure = job.topotest_failures.first

        return '' if failure.nil?

        "\t :no_entry_sign: #{failure.test_suite} #{failure.test_case} \n```\n#{failure.message}\n```\n"
      end

      def build_message(job)
        output = BambooCi::Result.fetch(job.job_ref, expand: 'testResults.failedTests.testResult.errors,artifacts')
        entry = output.dig('artifacts', 'artifact').find { |elem| elem['name'] == 'ErrorLog' }

        body = BambooCi::Download.build_log(entry.dig('link', 'href'))

        "```\n#{body}\n```\n"
      end

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
