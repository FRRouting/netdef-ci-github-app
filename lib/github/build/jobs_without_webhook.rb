#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs_without_webhook.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../bamboo_ci/result'
require_relative '../../helpers/delayed_job_lookup'
require_relative '../../helpers/github_logger'
require_relative '../../helpers/prometheus_metrics'
require_relative 'summary/pending_jobs'
require_relative 'summary_refresh'

module Github
  module Build
    # Jobs created with webhook: false never call /update/status (see WebhookDetector). Their status is read
    # from Bamboo every INTERVAL by a chain of Delayed Jobs, one chain per execution, until none of them is open.
    class JobsWithoutWebhook
      QUEUE = 'poll_jobs_without_webhook'
      INTERVAL = 120 # seconds
      AGENT = 'BambooPolling'

      def self.schedule(check_suite)
        return unless pollable?(check_suite)
        return if pending?(check_suite)

        PollJobsWithoutWebhook.delay(run_at: INTERVAL.seconds.from_now.utc, queue: QUEUE).poll(check_suite.id)
      end

      def self.poll(check_suite_id)
        check_suite = CheckSuite.find_by(id: check_suite_id)
        return if check_suite.nil? or !pollable?(check_suite)

        new(check_suite).poll
        schedule(check_suite)
      end

      # Stops once every job without webhook is final, the execution is closed or a newer one replaced it.
      def self.pollable?(check_suite)
        check_suite.ci_jobs.where(webhook: false, status: %i[queued in_progress]).exists? and
          check_suite.running? and !check_suite.superseded?
      end

      # The poll that is running is still in the table (locked) and must not stop its own next run.
      def self.pending?(check_suite)
        DelayedJobLookup
          .pending(method: :poll, first_arg: check_suite.id, queue: QUEUE)
          .where(locked_at: nil, failed_at: nil)
          .exists?
      end

      def initialize(check_suite)
        @check_suite = check_suite
        @github = Github::Check.new(check_suite)
        @pending_jobs = Summary::PendingJobs.new(@github, AGENT)
        @logger = GithubLogger.instance.create("pr#{check_suite.pull_request.github_pr_id}.log", Logger::INFO)
      end

      def poll
        open_jobs.each { |job| poll_job(job) }
      end

      private

      def open_jobs
        @check_suite.ci_jobs.where(webhook: false, status: %i[queued in_progress]).to_a
      end

      # An error on one job must not stop the chain: the next poll reads it again.
      def poll_job(job)
        attempt = job.retry.to_i
        result = fetch(job)
        return false unless result.is_a?(Hash)

        apply(job, attempt, result)
      rescue StandardError => e
        @logger.error("[#{self.class}] Polling #{job.job_ref} failed: #{e.class} #{e.message}")
        false
      end

      def fetch(job)
        PrometheusMetrics.track_bamboo('poll_job_without_webhook') do
          BambooCi::Result.fetch(job.job_ref, expand: '')
        end
      end

      # The Bamboo read takes time: a hook may have finished the job, or a retry re-queued it, meanwhile.
      # The status and its summary refresh are saved together, so a failed refresh leaves the job open and
      # the next poll applies the result again.
      def apply(job, attempt, result)
        job.with_lock(requires_new: true) do
          next false unless (job.queued? or job.in_progress?) and job.retry.to_i == attempt

          changed = update(job, result)
          SummaryRefresh.schedule(job) if changed
          changed
        end
      end

      def update(job, result)
        return start(job) if result['lifeCycleState'] == 'InProgress'

        @pending_jobs.sync_job(job, result)
      end

      def start(job)
        return false unless job.queued?

        job.in_progress(@github, agent: AGENT)
        true
      end
    end
  end
end
