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
      def initialize(check_suite, github, jobs, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @jobs = jobs
        @loggers = []
        @stages = StageConfiguration.all

        %w[github_app.log github_build_action.log].each do |filename|
          @loggers << GithubLogger.instance.create(filename, logger_level)
        end

        logger(Logger::INFO, "Building action to CheckSuite @#{@check_suite.inspect}")
      end

      def create_summary(rerun: false)
        logger(Logger::INFO, "SUMMARY #{@stages.inspect}")

        @stages.each do |stage_config|
          create_check_run_stage(stage_config)
        end

        logger(Logger::INFO, "@jobs - #{@jobs.inspect}")
        create_jobs(rerun)
      end

      private

      def create_jobs(rerun)
        @jobs.each do |job|
          ci_job = create_ci_job(job)

          if rerun
            next unless ci_job.stage.configuration.can_retry?

            url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
            ci_job.enqueue(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
          else
            ci_job.create_check_run
          end

          stage_with_start_in_progress(ci_job)
        end
      end

      def stage_with_start_in_progress(ci_job)
        return unless !ci_job.stage.nil? and ci_job.stage.configuration.start_in_progress?

        ci_job.in_progress(@github)
        ci_job.stage.in_progress(@github, output: {})
      end

      def create_ci_job(job)
        stage_config = StageConfiguration.find_by(bamboo_stage_name: job[:stage])

        stage = Stage.find_by(check_suite: @check_suite, name: stage_config.github_check_run_name)

        logger(Logger::INFO, "create_jobs - #{job.inspect} -> #{stage.inspect}")

        CiJob.create(check_suite: @check_suite, name: job[:name], job_ref: job[:job_ref], stage: stage)
      end

      def create_check_run_stage(stage_config)
        stage = Stage.find_by(name: stage_config.github_check_run_name, check_suite_id: @check_suite.id)

        logger(Logger::INFO, "STAGE #{stage_config.github_check_run_name} #{stage.inspect} - @#{@check_suite.inspect}")

        return create_stage(stage_config) if stage.nil?
        return unless stage.configuration.can_retry?

        logger(Logger::INFO, ">>> Enqueued #{stage.inspect}")

        stage.enqueue(@github, output: initial_output(stage))
      end

      def create_stage(stage_config)
        name = stage_config.github_check_run_name

        stage =
          Stage.create(check_suite: @check_suite,
                       configuration: stage_config,
                       status: 'queued',
                       name: name)

        url = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
        output = { title: "#{stage.name} summary", summary: "Uninitialized stage\nDetails at [#{url}](#{url})" }

        stage.enqueue(@github, output: output)
        stage.in_progress(@github) if stage_config.start_in_progress?

        stage
      end

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
