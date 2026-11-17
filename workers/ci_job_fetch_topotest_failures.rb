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
  def self.update(ci_job_id, count)
    @job = CiJob.find(ci_job_id)

    @retrieve_error = Github::TopotestFailures::RetrieveError.new(@job)
    @retrieve_error.retrieve

    return if rescheduled?(count)

    TopotestFailure.replace_for(@job, @retrieve_error.failures)
  end

  def self.rescheduled?(count)
    return true if count > 3

    if @retrieve_error.failures.empty?
      count += 1

      CiJobFetchTopotestFailures
        .delay(run_at: (5 * count).minutes.from_now, queue: 'fetch_topotest_failures')
        .update(@job.id, count)

      return true
    end

    false
  end
end
