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
  def self.update(ci_job_id)
    @job = CiJob.find(ci_job_id)

    @retrieve_error = Github::TopotestFailures::RetrieveError.new(@job)
    @retrieve_error.retrieve

    return if @retrieve_error.failures.empty?

    @failures = @retrieve_error.failures

    failures_stats
  end

  private

  def failures_stats
    @failures.each do |failure|
      TopotestFailure.create(ci_job: @job,
                             test_suite: failure['suite'],
                             test_case: failure['case'],
                             message: failure['message'],
                             execution_time: failure['execution_time'])
    end
  end
end
