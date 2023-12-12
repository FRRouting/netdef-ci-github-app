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

      def build_summary
        stage = @job.parent_stage

        logger(Logger::INFO, "build_summary: #{stage.inspect}")

        stage = fetch_parent_stage if stage.nil?

        update_summary(stage)
        finished_summary(stage)
        missing_stage(stage)
      end

      def missing_stage(stage)
        ParentStage.where(check_suite: @check_suite).where.not(name: stage.name).each do |pending_stage|
          next if pending_stage.jobs.where(status: %w[queue in_progress]).any?

          if pending_stage.bamboo_stage.position.to_i < stage.bamboo_stage.position.to_i
            next finished_summary(pending_stage)
          end

          previous_stage_failure(pending_stage, stage)
        end
      end

      def previous_stage_failure(pending_stage, stage)
        return unless can_update_previous_stage?(pending_stage, stage)

        stage.failure? ? next_stage_failure(pending_stage) : update_summary(pending_stage)
      end

      def can_update_previous_stage?(pending_stage, stage)
        pending_stage.bamboo_stage.position.to_i > stage.bamboo_stage.position.to_i or
          pending_stage.queued? or
          pending_stage.in_progress?
      end

      def next_stage_failure(pending_stage)
        url = "https://ci1.netdef.org/browse/#{pending_stage.check_suite.bamboo_ci_ref}"
        output = {
          title:
            "#{pending_stage.name} summary",
          summary:
            "The previous stage failed and the remaining tests will be canceled.\nDetails at [#{url}](#{url})."
        }

        pending_stage.cancelled(@github, output)
      end

      def finished_summary(stage)
        logger(Logger::INFO, "Finished stage: #{stage.inspect}, CiJob status: #{@job.status}")
        return if @job.in_progress? or stage.jobs.where(status: %w[queue in_progress]).any?

        finished_stage_summary(stage)
      end

      def finished_stage_summary(stage)
        logger(Logger::INFO, "finished_build_summary: #{stage.inspect}. Reason Job: #{@job.inspect}")

        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = {
          title: "#{stage.name} summary",
          summary: "#{summary_basic_output(stage)}\nDetails at [#{url}](#{url})."
        }

        stage.jobs.failure.empty? ? stage.success(@github, output) : stage.failure(@github, output)
      end

      def update_summary(stage)
        logger(Logger::INFO, "Updating summary status #{stage.inspect} -> @job.status: #{@job.status}")

        url = "https://ci1.netdef.org/browse/#{@check_suite.bamboo_ci_ref}"
        output = {
          title: "#{stage.name} summary",
          summary: "#{summary_basic_output(stage)}\nDetails at [#{url}](#{url})."
        }

        stage.in_progress(@github, output)
      end

      def summary_basic_output(stage)
        jobs = stage.jobs.reload
        in_progress = jobs.where(status: :in_progress)

        header = ":arrow_right: Jobs in progress: #{in_progress.size}/#{jobs.size}\n\n"
        header += in_progress_message(jobs)
        header += generate_success_failure_info(stage.name, jobs)

        header[0..65_535]
      end

      def generate_success_failure_info(name, jobs)
        header = ''

        [
          {
            title: ':heavy_multiplication_x: Jobs Failure',
            queue: other_message(name, jobs),
            size: jobs.where.not(status: %i[in_progress queued success]).size
          },
          {
            title: ':heavy_check_mark: Jobs Success',
            queue: success_message(jobs),
            size: jobs.where(status: :success).size
          }
        ].each do |info|
          next if info[:queue].nil? or info[:queue].empty?

          header += "\n#{info[:title]}: #{info[:size]}/#{jobs.size}\n\n#{info[:queue]}"
        end

        header
      end

      private

      def in_progress_message(jobs)
        jobs.where(status: :in_progress).map do |job|
          "- **#{job.name}** -> https://ci1.netdef.org/browse/#{job.job_ref}\n"
        end.join("\n")
      end

      def success_message(jobs)
        jobs.where(status: :success).map do |job|
          "- **#{job.name}** -> https://ci1.netdef.org/browse/#{job.job_ref}\n"
        end.join("\n")
      end

      def other_message(name, jobs)
        jobs.where.not(status: %i[in_progress queued success]).map do |job|
          generate_message(name, job)
        end.join("\n")
      end

      def generate_message(name, job)
        failures = name.downcase.match?('build') ? build_message(job) : tests_message(job)

        "- #{job.name} -> https://ci1.netdef.org/browse/#{job.job_ref}\n#{failures}"
      end

      def tests_message(job)
        failure = job.topotest_failures.first

        return '' if failure.nil?

        "\t :no_entry_sign: #{failure.test_suite} #{failure.test_case}\n ```\n#{failure.message}\n```\n"
      end

      def build_message(job)
        output = BambooCi::Result.fetch(job.job_ref, expand: 'testResults.failedTests.testResult.errors,artifacts')
        entry = output.dig('artifacts', 'artifact')&.find { |elem| elem['name'] == 'ErrorLog' }

        return '' if entry.nil? or entry.empty?

        body = BambooCi::Download.build_log(entry.dig('link', 'href'))

        "```\n#{body}\n```\n"
      end

      def fetch_parent_stage
        jobs = BambooCi::RunningPlan.fetch(@check_suite.bamboo_ci_ref)
        info = jobs.find { |job| job[:name] == @job.name }
        stage = ParentStage.find_by(check_suite: @check_suite, name: info[:stage])

        @job.update(parent_stage: stage)

        stage
      end

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
