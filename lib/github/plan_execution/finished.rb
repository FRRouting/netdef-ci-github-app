#  SPDX-License-Identifier: BSD-2-Clause
#
#  check_suite_finished.rb
#  Part of NetDEF CI System
#
#  This class handles the logic for determining if a CheckSuite has finished execution.
#  It interacts with the Bamboo CI system to fetch the build status and updates the CheckSuite accordingly.
#
#  Methods:
#  - initialize(payload): Initializes the Finished class with the given payload.
#  - finished: Main method to handle the completion logic for a CheckSuite.
#  - fetch_build_status: Fetches the build status from Bamboo CI.
#  - in_progress?(build_status): Checks if the CI build is still in progress.
#
#  Example usage:
#    Github::PlanExecution::Finished.new(payload).finished
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

      ##
      # Initializes the Finished class with the given payload.
      #
      # @param [Hash] payload The payload containing information about the CheckSuite.
      def initialize(payload)
        @bamboo_ref = BambooRef.find_by(bamboo_key: payload['bamboo_ref']) if payload['bamboo_ref']
        @check_suite = @bamboo_ref.check_suite if @bamboo_ref
        @check_suite = CheckSuite.find(payload['check_suite_id']) if payload['check_suite_id']
        @logger = GithubLogger.instance.create('github_plan_execution_finished.log', Logger::INFO)
        @hanged = payload['hanged'] || false
      end

      ##
      # Main method to handle the completion logic for a CheckSuite.
      # Fetches the CI execution status and updates the CheckSuite accordingly.
      #
      # @return [Array] An array containing the status code and message.
      def finished
        @logger.info ">>> Check Suite: #{@check_suite.inspect}"

        return [404, 'Check Suite not found'] if @check_suite.nil?

        fetch_ci_execution
        build_status = fetch_build_status(@bamboo_ref.bamboo_key)

        @logger.info ">>> build_status: #{build_status.inspect}. Hanged? #{@hanged}"

        return [200, 'Still running'] if in_progress?(build_status) and !@hanged

        check_stages
        clear_deleted_jobs
        update_all_stages

        [200, 'Finished']
      end

      ##
      # Fetches the build status from Bamboo CI.
      #
      # @return [Hash] The build status.
      def fetch_build_status(bamboo_key)
        get_request(URI("https://127.0.0.1/rest/api/latest/result/status/#{bamboo_key}"))
      end

      ##
      # Checks if the CI build is still in progress.
      #
      # @param [Hash] build_status The build status.
      # @return [Boolean] Returns true if the build is still in progress, false otherwise.
      def in_progress?(build_status)
        @logger.info ">>> ci_stopped?: #{ci_stopped?(build_status)}"
        @logger.info ">>> ci_hanged?: #{ci_hanged?(build_status)}"

        return false if ci_hanged?(build_status)
        return false if build_status['currentStage'].casecmp('final').zero?

        true
      end

      private

      ##
      # Updates the status of all stages for the CheckSuite.
      # Builds a summary for the last stage's last job.
      def update_all_stages
        last_stage =
          Stage
          .joins(:configuration)
          .where(check_suite: @check_suite)
          .max_by { |stage| stage.configuration.position }

        return if last_stage.nil? or last_stage.jobs.last.nil?

        build_summary(last_stage.jobs.last)
      end

      ##
      # Moves all tests that no longer exist in BambooCI to the skipped state.
      def clear_deleted_jobs
        github_check = Github::Check.new(@check_suite)

        @check_suite.ci_jobs.where(status: %w[queued in_progress]).each do |ci_job|
          ci_job.skipped(github_check)
        end
      end

      ##
      # Checks if the CI build has stopped.
      #
      # @param [Hash] build_status The build status.
      # @return [Boolean] Returns true if the build has stopped, false otherwise.
      def ci_stopped?(build_status)
        build_status.key?('message') and !build_status.key?('finished')
      end

      ##
      # Checks if the CI build has hanged.
      #
      # @param [Hash] build_status The build status.
      # @return [Boolean] Returns true if the build has hanged, false otherwise.
      def ci_hanged?(build_status)
        return true if ci_stopped?(build_status)

        build_status.dig('progress', 'percentageCompleted').to_f >= 2.0
      end

      ##
      # Updates the status of a stage based on the CI job result.
      #
      # @param [CiJob] ci_job The CI job to update.
      # @param [Hash] result The result of the CI job.
      # @param [Github::Check] github The Github check instance.
      def update_stage_status(ci_job, result, github)
        return if ci_job.nil? || (ci_job.finished? && !ci_job.job_ref.nil?)

        update_ci_job_status(github, ci_job, result['state'])
      end

      ##
      # Updates the status of a CI job based on the state.
      #
      # @param [Github::Check] github_check The Github check instance.
      # @param [CiJob] ci_job The CI job to update.
      # @param [String] state The state of the CI job.
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

      ##
      # Creates an output message for a CI job.
      #
      # @param [CiJob] ci_job The CI job to create the message for.
      # @return [Hash] The output message.
      def create_output_message(ci_job)
        url = "https://#{GitHubApp::Configuration.instance.config['ci']['url']}/browse/#{ci_job.job_ref}"

        {
          title: ci_job.name,
          summary: "Details at [#{url}](#{url})\nUnfortunately we were unable to access the execution results."
        }
      end

      ##
      # Builds a summary for a CI job.
      #
      # @param [CiJob] ci_job The CI job to build the summary for.
      def build_summary(ci_job)
        summary = Github::Build::Summary.new(ci_job, agent: 'WatchDog')
        summary.build_summary

        finished_execution?(ci_job.check_suite)
      end

      ##
      # Checks if the execution of the CheckSuite has finished.
      #
      # @param [CheckSuite] check_suite The CheckSuite to check.
      # @return [Boolean] Returns true if the execution has finished, false otherwise.
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

      ##
      # Checks the stages of the CheckSuite and updates their status.
      def check_stages
        github_check = Github::Check.new(@check_suite)
        @logger.info ">>> @result: #{@result.inspect}"
        return if @result.nil? or @result.empty? or @result['status-code']&.between?(400, 500)

        @result.dig('stages', 'stage').each do |stage|
          stage.dig('results', 'result').each do |result|
            ci_job = CiJob.find_by(job_ref: result['buildResultKey'], check_suite_id: @check_suite.id)

            update_stage_status(ci_job, result, github_check)
          end
        end
      end

      ##
      # Fetches the CI execution status for the CheckSuite.
      def fetch_ci_execution
        @result = get_status(@check_suite.bamboo_ci_ref)
      end
    end
  end
end
