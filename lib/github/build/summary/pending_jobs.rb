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
        def initialize(github, agent)
          @github = github
          @agent = agent
        end

        def sync(stage)
          stage.jobs.where(status: %i[queued in_progress]).each { |job| sync_job(job) }
        end

        private

        def sync_job(job)
          result = BambooCi::Result.fetch(job.job_ref, expand: '')
          return unless result.is_a?(Hash)

          case result['state']
          when 'Successful' then job.success(@github, agent: @agent)
          when 'Failed' then failed(job)
          else return
          end

          job.update_execution_time
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
