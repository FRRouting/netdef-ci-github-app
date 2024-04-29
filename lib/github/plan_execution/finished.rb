#  SPDX-License-Identifier: BSD-2-Clause
#
#  check_suite_finished.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../slack_bot/slack_bot'
require_relative '../../github/build/action'
require_relative '../../github/build/summary'

module Github
  module PlanExecution
    class Finished
      include BambooCi::Api

      def initialize(payload)
        @check_suite = CheckSuite.find_by(bamboo_ci_ref: payload['bamboo_ref'])
        @logger = GithubLogger.instance.create('github_plan_execution_finished.log', Logger::INFO)
      end

      def finished
        @logger.info ">>> Check Suite: #{@check_suite.inspect}"

        return [404, 'Check Suite not found'] if @check_suite.nil?

        fetch_ci_execution
        build_status = fetch_build_status

        @logger.info ">>> build_status: #{build_status.inspect}"

        return [200, 'Still running'] if in_progress?(build_status)

        check_stages
        clear_deleted_jobs

        [200, 'Finished']
      end

      private

      # This method will move all tests that no longer exist in BambooCI to the skipped state,
      # because there are no executions for them.
      def clear_deleted_jobs
        github_check = Github::Check.new(@check_suite)

        @check_suite.ci_jobs.where(status: %w[queued in_progress]).each do |ci_job|
          ci_job.skipped(github_check)
        end
      end

      # Checks if CI still running
      def in_progress?(build_status)
        @logger.info ">>> ci_stopped?: #{ci_stopped?(build_status)}"
        @logger.info ">>> ci_hanged?: #{ci_hanged?(build_status)}"

        return false if ci_hanged?(build_status)
        return false if build_status['currentStage'].casecmp('final').zero?

        true
      end

      def ci_stopped?(build_status)
        build_status.key?('message') and !build_status.key?('finished')
      end

      def ci_hanged?(build_status)
        return true if ci_stopped?(build_status)

        build_status.dig('progress', 'percentageCompleted').to_f >= 2.0
      end

      def update_stage_status(ci_job, result, github)
        return if ci_job.nil? || (ci_job.finished? && !ci_job.job_ref.nil?)

        update_ci_job_status(github, ci_job, result['state'])
      end

      def update_ci_job_status(github_check, ci_job, state)
        ci_job.enqueue(github_check) if ci_job.job_ref.nil?

        output = create_output_message(ci_job)

        case state
        when 'Unknown'
          ci_job.cancelled(github_check, output: output, agent: 'WatchDog')
          slack_notify_cancelled(ci_job)
        when 'Failed'
          ci_job.failure(github_check, output: output, agent: 'WatchDog')
          slack_notify_failure(ci_job)
        when 'Successful'
          ci_job.success(github_check, output: output, agent: 'WatchDog')
          slack_notify_success(ci_job)
        else
          puts 'Ignored'
        end

        build_summary(ci_job)
      end

      def create_output_message(ci_job)
        url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"

        {
          title: ci_job.name,
          summary: "Details at [#{url}](#{url})\nUnfortunately we were unable to access the execution results."
        }
      end

      def build_summary(ci_job)
        summary = Github::Build::Summary.new(ci_job, agent: 'WatchDog')
        summary.build_summary

        finished_execution?(ci_job.check_suite)
      end

      def finished_execution?(check_suite)
        return false unless check_suite.pull_request.current_execution?(check_suite)
        return false unless check_suite.finished?

        SlackBot.instance.execution_finished_notification(check_suite)
      end

      def slack_notify_success(job)
        SlackBot.instance.notify_success(job)
      end

      def slack_notify_failure(job)
        SlackBot.instance.notify_errors(job)
      end

      def slack_notify_cancelled(job)
        SlackBot.instance.notify_cancelled(job)
      end

      def check_stages
        github_check = Github::Check.new(@check_suite)
        @logger.info ">>> @result: #{@result.inspect}"
        @result.dig('stages', 'stage').each do |stage|
          stage.dig('results', 'result').each do |result|
            ci_job = CiJob.find_by(job_ref: result['buildResultKey'], check_suite_id: @check_suite.id)

            update_stage_status(ci_job, result, github_check)
          end
        end
      end

      def fetch_ci_execution
        @result = get_status(@check_suite.bamboo_ci_ref)
      end

      def fetch_build_status
        get_request(URI("https://127.0.0.1/rest/api/latest/result/status/#{@check_suite.bamboo_ci_ref}"))
      end
    end
  end
end
