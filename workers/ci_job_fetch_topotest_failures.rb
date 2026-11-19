#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job_fetch_topotest_failures.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class CiJobFetchTopotestFailures
  # attempt is the CiJob retry that failed, taken when the fetch was scheduled. Jobs enqueued before it
  # was passed fall back to the current one.
  def self.update(ci_job_id, count, attempt = nil)
    @job = CiJob.find(ci_job_id)
    @attempt = attempt.nil? ? @job.retry.to_i : attempt

    return if stale?

    @retrieve_error = Github::TopotestFailures::RetrieveError.new(@job)
    @retrieve_error.retrieve

    return if stale? or rescheduled?(count)

    TopotestFailure.replace_for(@job, @retrieve_error.failures, attempt: @attempt)
  end

  # Bamboo only keeps the latest result of a job_ref: once a ci:retry started another attempt (checked
  # again after the read, as the retry may start meanwhile) it would return that attempt's failures.
  def self.stale?
    @job.reload.retry.to_i != @attempt
  end

  def self.rescheduled?(count)
    return true if count > 3

    if @retrieve_error.failures.empty?
      count += 1

      CiJobFetchTopotestFailures
        .delay(run_at: (5 * count).minutes.from_now, queue: 'fetch_topotest_failures')
        .update(@job.id, count, @attempt)

      return true
    end

    false
  end
end
