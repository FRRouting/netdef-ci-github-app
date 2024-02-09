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
require_relative '../../bamboo_ci/running_plan'
require_relative '../../helpers/github_logger'

module Github
  module Build
    class Summary
      def initialize(job, logger_level: Logger::INFO, agent: 'Github')
        @job = job.reload
        @check_suite = @job.check_suite
        @github = Github::Check.new(@check_suite)
        @loggers = []
        @agent = agent

        %w[github_app.log github_build_summary.log].each do |filename|
          @loggers << GithubLogger.instance.create(filename, logger_level)
        end
      end

      def build_summary
        current_stage = @job.stage
        current_stage = fetch_parent_stage if current_stage.nil?
        check_and_update_github_ref(current_stage)

        logger(Logger::INFO, "build_summary: #{current_stage.inspect}")

        # Update current stage
        update_summary(current_stage)
        # Check if current stage finished
        finished_summary(current_stage)
        # If current stage fails the next stages will be marked as failure
        # when current stage has mandatory field is true
        must_cancel_next_stages(current_stage)
        # If current stage passes the next stage will be marked as in_progress
        must_continue_next_stage(current_stage)
        # If previous stage still in progress or queued
        must_update_previous_stage(current_stage)
      end

      private

      def check_and_update_github_ref(current_stage)
        current_refs = @github.fetch_check_runs

        logger(Logger::INFO,
               'check_and_update_github_ref - current_stage: ' \
               "#{current_stage.inspect} current_refs: #{current_refs.inspect}")

        return if current_refs.include? current_stage.check_ref.to_i

        logger(Logger::INFO,
               'check_and_update_github_ref - current_stage: ' \
               "#{current_stage.inspect} current_refs: #{current_refs.inspect} - Refreshing reference.")

        current_stage.refresh_reference(@github)
      end

      def must_update_previous_stage(current_stage)
        previous_stage = current_stage.previous_stage

        return if previous_stage.nil? or !(previous_stage.in_progress? or previous_stage.queued?)

        finished_stage_summary(previous_stage)
      end

      def must_cancel_next_stages(current_stage)
        return if @job.success? or @job.in_progress? or @job.queued?
        return unless current_stage.configuration.mandatory?

        Stage
          .joins(:configuration)
          .where(check_suite: @check_suite)
          .where(configuration: { position: [(current_stage.configuration.position + 1)..] })
          .each do |stage|
          next if stage.cancelled?

          cancelling_next_stage(stage)
        end
      end

      def must_continue_next_stage(current_stage)
        return unless current_stage.finished?
        return if current_stage.failure? or current_stage.skipped? or current_stage.cancelled?

        next_stage =
          Stage
          .joins(:configuration)
          .where(check_suite: @check_suite)
          .where(configuration: { position: current_stage.configuration.position + 1 })
          .first

        return if next_stage.nil?

        update_summary(next_stage)
      end

      def cancelling_next_stage(pending_stage)
        url = "https://ci1.netdef.org/browse/#{pending_stage.check_suite.bamboo_ci_ref}"
        output = {
          title:
            "#{pending_stage.name} summary",
          summary:
            "The previous stage failed and the remaining tests will be canceled.\nDetails at [#{url}](#{url})."
        }

        logger(Logger::INFO, "cancelling_next_stage - pending_stage: #{pending_stage.inspect}\n#{output}")

        pending_stage.cancelled(@github, output: output)
        pending_stage.jobs.each { |job| job.cancelled(@github) }
      end

      def finished_summary(stage)
        logger(Logger::INFO, "Finished stage: #{stage.inspect}, CiJob status: #{@job.status}")
        logger(Logger::INFO, "Finished stage: #{stage.inspect}, jobs: #{stage.reload.jobs.inspect}")

        return if @job.in_progress? or stage.running?

        finished_stage_summary(stage)
      end

      def finished_stage_summary(stage)
        logger(Logger::INFO, "finished_build_summary: #{stage.inspect}. Reason Job: #{@job.inspect}")

        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = {
          title: "#{stage.name} summary",
          summary: "#{summary_basic_output(stage)}\nDetails at [#{url}](#{url}).".force_encoding('utf-8')
        }

        logger(Logger::INFO, "finished_stage_summary: #{stage.inspect} #{output.inspect}")

        if stage.jobs.failure.empty?
          stage.success(@github, output: output, agent: @agent)
        else
          stage.failure(@github, output: output, agent: @agent)
        end
      end

      def update_summary(stage)
        logger(Logger::INFO, "Updating summary status #{stage.inspect} -> @job.status: #{@job.status}")

        url = "https://ci1.netdef.org/browse/#{@check_suite.bamboo_ci_ref}"
        output = {
          title: "#{stage.name} summary",
          summary: "#{summary_basic_output(stage)}\nDetails at [#{url}](#{url}).".force_encoding('utf-8')
        }

        logger(Logger::INFO, "update_summary: #{stage.inspect} #{output.inspect}")

        stage.in_progress(@github, output: output)
        stage.update_output(@github, output: output)
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

      def in_progress_message(jobs)
        jobs.where(status: %i[in_progress queued]).map do |job|
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

        stage = first_or_create_stage(info)

        logger(Logger::INFO, "fetch_parent_stage - stage: #{stage.inspect} info[:stage]: #{info[:stage]}")

        @job.update(stage: stage)

        stage
      end

      def first_or_create_stage(info)
        config = StageConfiguration.find_by(bamboo_stage_name: info[:stage])
        stage = Stage.find_by(check_suite: @check_suite, name: info[:stage])
        stage = Stage.create(check_suite: @check_suite, name: info[:stage], configuration: config) if stage.nil?

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
