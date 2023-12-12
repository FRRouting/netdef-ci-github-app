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
      def initialize(check_suite, github, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @loggers = []
        @stages = BambooStageTranslation.all

        %w[github_app.log github_build_action.log].each do |filename|
          logger_app = Logger.new(filename, 1, 1_024_000)
          logger_app.level = logger_level

          @loggers << logger_app
        end

        logger(Logger::INFO, "Building action to CheckSuite @#{@check_suite.inspect}")
      end

      def create_summary
        logger(Logger::INFO, "SUMMARY #{@stages.inspect}")

        @stages.each do |stage|
          create_check_run_stage(stage.github_check_run_name, stage.start_in_progress)
        end
      end

      def create_stage(name, in_progress)
        bamboo_ci = @check_suite.bamboo_ci_ref.split('-').last

        stage =
          CiJob.create(check_suite: @check_suite, name: name, job_ref: "#{name}-#{bamboo_ci}", stage: true)

        return nil unless stage.persisted?

        url = "https://ci1.netdef.org/browse/#{stage.job_ref}"
        output = { title: stage.name, summary: "Details at [#{url}](#{url})" }

        stage.enqueue(@github, output)
        stage.in_progress(@github, output) if in_progress

        stage
      end

      def create_jobs(jobs, rerun: false)
        jobs.each do |job|
          parent_stage = BambooStageTranslation.find_by(bamboo_stage_name: job[:stage])

          stage =
            CiJob.find_by(check_suite: @check_suite, name: parent_stage.github_check_run_name)

          ci_job =
            CiJob.create(check_suite: @check_suite,
                         name: job[:name], job_ref: job[:job_ref], parent_stage_id: stage.id)

          next unless ci_job.persisted?

          if rerun
            next if ci_job.checkout_code?

            url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
            ci_job.enqueue(@github, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
          else
            ci_job.create_check_run
          end
        end
      end

      private

      def create_check_run_stage(name, in_progress)
        stage = CiJob.find_by(name: name, check_suite_id: @check_suite.id)

        logger(Logger::INFO, "STAGE #{name} #{stage.inspect} - @#{@check_suite.inspect}")

        return create_stage(name, in_progress) if stage.nil?

        logger(Logger::INFO, ">>> Enqueued #{stage.inspect}")

        stage.enqueue(@github, initial_output(stage))
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
