#  SPDX-License-Identifier: BSD-2-Clause
#
#  pending_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../../bamboo_ci/result'

module Github
  module Build
    class Summary
      # Bamboo only starts a stage after the previous ones finished, so a job of an earlier stage that is
      # still queued/in_progress here lost its status update (e.g. the Checkout Code hook never fired).
      # Its result is read from Bamboo instead of leaving the stage stuck.
      class PendingJobs
        QUEUE = 'sync_pending_jobs'
        CONFIRM_ATTEMPTS = 5
        CONFIRM_INTERVAL = 60 # seconds, multiplied by the attempt: 0, 1, 2, 3 and 4 minutes later

        # Summary runs inside webhooks, so the Bamboo reads happen in a Delayed Job, once per stage at a time.
        def self.schedule(stage, agent)
          return if DelayedJobLookup.pending(method: :sync, first_arg: stage.id, queue: QUEUE).exists?

          SyncPendingJobs.delay(queue: QUEUE).sync(stage.id, agent)
        end

        # Once Bamboo's results close the stage, its summary is built again like for any finished job.
        # Guarded by the stage status, not its jobs: a retry after a GitHub error must still finish the
        # summary of a stage whose jobs were already saved as finished.
        def self.sync_stage(stage_id, agent)
          stage = Stage.find_by(id: stage_id)
          return if stage.nil? or !(stage.queued? or stage.in_progress?)

          new(Github::Check.new(stage.check_suite), agent).sync(stage)
          finish_stage(stage, agent)
        end

        # A queued job whose end hook arrived (Github::UpdateStatus). Bamboo sends that hook from a task inside
        # the job, so its result is often not Finished yet when the first read happens: it is read again, at
        # most CONFIRM_ATTEMPTS times, before giving up.
        def self.schedule_confirm(job, agent, attempt = 1)
          return if attempt == 1 and DelayedJobLookup.pending(method: :confirm, first_arg: job.id, queue: QUEUE).exists?

          SyncPendingJobs
            .delay(run_at: ((attempt - 1) * CONFIRM_INTERVAL).seconds.from_now.utc, queue: QUEUE)
            .confirm(job.id, agent, attempt)
        end

        # A job already saved as finished does not read Bamboo again, but its stage summary is still built while
        # the stage is open: a retry after the summary failed must not leave the stage stuck.
        def self.confirm_job(job_id, agent, attempt)
          job = CiJob.find_by(id: job_id)
          stage = job&.stage
          return if stage.nil?
          return finish_open_stage(stage, agent) unless job.queued? or job.in_progress?
          return finish_stage(stage, agent) if new(Github::Check.new(job.check_suite), agent).sync_job(job)

          schedule_confirm(job, agent, attempt + 1) if attempt < CONFIRM_ATTEMPTS
        end

        def self.finish_open_stage(stage, agent)
          finish_stage(stage, agent) if stage.queued? or stage.in_progress?
        end

        def self.finish_stage(stage, agent)
          last_job = stage.reload.jobs.last

          return if stage.running? or last_job.nil?

          Github::Build::Summary.new(last_job, agent: agent).build_summary
        end

        def initialize(github, agent)
          @github = github
          @agent = agent
        end

        def sync(stage)
          stage.jobs.where(status: %i[queued in_progress]).each { |job| sync_job(job) }
        end

        # Saves the final result Bamboo gives for the job. Also used by JobsWithoutWebhook with the result it
        # already read. Returns whether the job changed.
        def sync_job(job, result = BambooCi::Result.fetch(job.job_ref, expand: ''))
          return false unless current_result?(job, result)

          case result['state']
          when 'Successful' then job.success(@github, agent: @agent)
          when 'Failed' then failed(job)
          else return false
          end

          job.update_execution_time
          true
        end

        private

        # Bamboo keeps only the latest result of a job key. Until it restarts a job that a retry re-queued,
        # that result is still the attempt that failed, so it only counts when it finished after the re-queue.
        def current_result?(job, result)
          return false unless result.is_a?(Hash) and result['lifeCycleState'] == 'Finished'
          return true if job.retry.to_i.zero?

          requeued = job.audit_statuses.where(status: :queued).maximum(:created_at)
          completed = completed_time(result)

          requeued.nil? or (!completed.nil? and completed >= requeued)
        end

        def completed_time(result)
          Time.iso8601(result['buildCompletedTime'].to_s)
        rescue ArgumentError
          nil
        end

        # Same follow-up as a failure reported by Bamboo (Github::UpdateStatus), so the job gets its failure details.
        def failed(job)
          job.failure(@github, agent: @agent)

          CiJobFetchTopotestFailures
            .delay(run_at: 5.minutes.from_now.utc, queue: 'fetch_topotest_failures')
            .update(job.id, 1, job.retry.to_i)
        end
      end
    end
  end
end
