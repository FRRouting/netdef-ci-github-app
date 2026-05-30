#  SPDX-License-Identifier: BSD-2-Clause
#
#  action.rb
#  Part of NetDEF CI System
#
#  This class handles the build action for a given CheckSuite.
#  It creates summaries, jobs, and timeout workers for the CheckSuite.
#
#  Methods:
#  - initialize(check_suite, github, jobs, logger_level: Logger::INFO): Initializes the Action class with the
#    given parameters.
#  - create_summary(rerun: false): Creates a summary for the CheckSuite, including jobs and timeout workers.
#
#  Example usage:
#    Github::Build::Action.new(check_suite, github, jobs).create_summary
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    class Action
      ##
      # Initializes the Action class with the given parameters.
      #
      # @param [CheckSuite] check_suite The CheckSuite to handle.
      # @param [Github] github The Github instance to use.
      # @param [Array] jobs The jobs to create for the CheckSuite.
      # @param [Integer] logger_level The logging level to use (default: Logger::INFO).
      def initialize(check_suite, github, jobs, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @jobs = jobs
        @loggers = []
        @stages = StageConfiguration.all

        %w[github_app.log github_build_action.log].each do |filename|
          @loggers << GithubLogger.instance.create(filename, logger_level)
        end
        @loggers << GithubLogger.instance.create("pr#{@check_suite.pull_request.github_pr_id}.log", logger_level)

        logger(Logger::WARN, ">>>> Building action to CheckSuite: #{@check_suite.inspect}")
      end

      ##
      # Creates a summary for the CheckSuite, including jobs and timeout workers.
      #
      # @param [Boolean] rerun Indicates if the jobs should be rerun (default: false).
      def create_summary(rerun: false)
        logger(Logger::INFO, "SUMMARY #{@stages.inspect}")

        Github::Build::SkipOldTests.new(@check_suite).skip_old_tests

        @stages.each do |stage_config|
          create_check_run_stage(stage_config)
        end

        logger(Logger::INFO, "@jobs - #{@jobs.inspect}")
        create_jobs(rerun)
        create_timeout_worker
      end

      private

      ##
      # Creates jobs for the CheckSuite.
      #
      # @param [Boolean] rerun Indicates if the jobs should be rerun.
      def create_jobs(rerun)
        @jobs.each do |job|
          ci_job = create_ci_job(job)

          next if ci_job.nil?

          if rerun
            next unless ci_job.stage.configuration.can_retry?

            url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{ci_job.job_ref}"
            ci_job.enqueue(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
          else
            ci_job.create_check_run
          end

          stage_with_start_in_progress(ci_job)
        end
      end

      ##
      # Creates a timeout worker for the CheckSuite.
      def create_timeout_worker
        logger(Logger::INFO, "CiJobStatus::Update: TimeoutExecution for '#{@check_suite.id}'")

        TimeoutExecution
          .delay(run_at: 30.minute.from_now.utc, queue: 'timeout_execution')
          .timeout(@check_suite.id)
      end

      ##
      # Starts the stage in progress if configured to do so.
      #
      # @param [CiJob] ci_job The CI job to start in progress.
      def stage_with_start_in_progress(ci_job)
        return unless !ci_job.stage.nil? and ci_job.stage.configuration.start_in_progress?

        ci_job.in_progress(@github)
        ci_job.stage.in_progress(@github, output: {})
      end

      ##
      # Creates a CI job for the given job parameters.
      #
      # @param [Hash] job The job parameters.
      # @return [CiJob, nil] The created CI job or nil if the stage configuration is not found.
      def create_ci_job(job)
        stage_config = StageConfiguration.find_by(bamboo_stage_name: job[:stage])

        return if stage_config.nil?

        stage = Stage.find_by(check_suite: @check_suite, name: stage_config.github_check_run_name)

        logger(Logger::INFO, "create_jobs - #{job.inspect} -> #{stage.inspect}")

        CiJob.create(check_suite: @check_suite, name: job[:name], job_ref: job[:job_ref], stage: stage)
      end

      ##
      # Creates a check run stage for the given stage configuration.
      #
      # @param [StageConfiguration] stage_config The stage configuration.
      def create_check_run_stage(stage_config)
        stage = Stage.find_by(name: stage_config.github_check_run_name, check_suite_id: @check_suite.id)

        logger(Logger::INFO, "STAGE #{stage_config.github_check_run_name} #{stage.inspect} - @#{@check_suite.inspect}")

        return create_stage(stage_config) if stage.nil?
        return unless stage.configuration.can_retry?

        logger(Logger::INFO, ">>> Enqueued #{stage.inspect}")

        stage.enqueue(@github, output: initial_output(stage))
      end

      ##
      # Creates a new stage for the given stage configuration.
      #
      # @param [StageConfiguration] stage_config The stage configuration.
      # @return [Stage] The created stage.
      def create_stage(stage_config)
        name = stage_config.github_check_run_name

        stage =
          Stage.create(check_suite: @check_suite,
                       configuration: stage_config,
                       status: 'queued',
                       name: name)

        url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = { title: "#{stage.name} summary", summary: "Uninitialized stage\nDetails at [#{url}](#{url})" }

        stage.enqueue(@github, output: output)
        stage.in_progress(@github) if stage_config.start_in_progress?

        stage
      end

      ##
      # Generates the initial output for a CI job.
      #
      # @param [CiJob] ci_job The CI job.
      # @return [Hash] The initial output.
      def initial_output(ci_job)
        output = { title: '', summary: '' }
        url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{ci_job.check_suite.bamboo_ci_ref}"

        output[:title] = "#{ci_job.name} summary"
        output[:summary] = "Details at [#{url}](#{url})"

        output
      end

      ##
      # Logs a message with the given severity.
      #
      # @param [Integer] severity The severity level.
      # @param [String] message The message to log.
      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
