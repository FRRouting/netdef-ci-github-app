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
      REVERT_QUEUE = 'revert_retry_check'
      REVERT_DELAY = 1 # minute
      REVERTABLE = %w[Stage CiJob].freeze

      # GitHub side of a revert that failed. Skipped once something else (a new retry) moved the check on.
      def self.sync_reverted_check(record_class, record_id, output)
        return unless REVERTABLE.include?(record_class)

        record = record_class.constantize.find_by(id: record_id)
        return if record.nil? or !record.failure?

        record.failure(Github::Check.new(record.check_suite), output: output)
      end

      def initialize(check_suite, github, audit_retry, logger_level: Logger::INFO)
        @check_suite = check_suite
        @github = github
        @loggers = []
        @stages_config = StageConfiguration.order(:position, :id)
        @audit_retry = audit_retry

        %w[github_app.log github_build_retry.log].each do |filename|
          @loggers << GithubLogger.instance.create(filename, logger_level)
        end
        @loggers << GithubLogger.instance.create("pr#{@check_suite.pull_request.github_pr_id}.log", logger_level)
        logger(Logger::WARN, ">>>> Retrying check_suite: #{@check_suite.inspect}")
      end

      def enqueued_stages
        @stages_config.each do |bamboo_stage|
          next unless bamboo_stage.can_retry?

          # By configuration, not name: the name may carry the plan suffix (see Action#stage_name).
          stage = Stage.find_by(check_suite: @check_suite, configuration: bamboo_stage)

          next if stage.nil?
          next if stage.success?

          stage.enqueue(@github, output: Github::Build::Action.stage_output(stage))
          enqueued_stages_list << stage
        end
      end

      def enqueued_failure_tests
        @check_suite.ci_jobs.where.not(status: :success).each do |ci_job|
          next if must_skip_retry?(ci_job)

          logger(Logger::WARN, "Enqueue CiJob: #{ci_job.inspect}")
          ci_job.enqueue(@github)
          ci_job.update(retry: ci_job.retry + 1)
          @audit_retry.ci_jobs << ci_job
          @audit_retry.save
        end
      end

      # Puts what this retry enqueued back to failure (and its jobs back to their failed attempt) when Bamboo
      # did not restart the build, so the stages can be retried again instead of staying queued until the
      # timeout. Best effort per check.
      def revert(reason)
        output = { title: 'Retry failed', summary: reason }

        (enqueued_stages_list + @audit_retry.ci_jobs.to_a).each { |record| revert_record(record, output) }
      end

      private

      def revert_record(record, output)
        # The failure details are read by attempt, so the job goes back to the attempt that failed.
        record.update(retry: [record.retry.to_i - 1, 0].max) if record.is_a?(CiJob)
        record.failure(@github, output: output)
      rescue StandardError => e
        logger(Logger::ERROR, "Could not revert #{record.class} #{record.id}: #{e.class}: #{e.message}")
        save_failure(record, output)
      end

      # Retry::Base#start rejects a retry while a check is queued, so the failure is saved without
      # waiting for GitHub, whose update is tried again in a Delayed Job.
      def save_failure(record, output)
        record.update(status: :failure)

        RevertRetryCheck
          .delay(run_at: REVERT_DELAY.minutes.from_now.utc, queue: REVERT_QUEUE)
          .sync(record.class.name, record.id, output)
      end

      def enqueued_stages_list
        @enqueued_stages_list ||= []
      end

      def must_skip_retry?(ci_job)
        ci_job.stage.nil? || !ci_job.stage.configuration.can_retry?
      end

      def logger(severity, message)
        @loggers.each do |logger_object|
          logger_object.add(severity, message)
        end
      end
    end
  end
end
