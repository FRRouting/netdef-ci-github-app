#  SPDX-License-Identifier: BSD-2-Clause
#
#  retrieve_address_sanitizer_error.rb
#
#  > Overview
#  The retrieve_address_sanitizer_error.rb script is part of the NetDEF CI System.
#  It is designed to retrieve and log AddressSanitizer errors from CI jobs that have failed.
#  The script processes CI jobs, retrieves errors using the Github::TopotestFailures::RetrieveError class,
#  and logs these errors into the TopotestFailure model.
#
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

# Only the job's current attempt counts: a partial retry reuses the CiJob, so failures saved for an earlier
# attempt must not stop this one from being filled in (the summary only shows the current attempt).
NO_FAILURES_FOR_CURRENT_ATTEMPT = <<~SQL.squish
  NOT EXISTS (
    SELECT 1 FROM topotest_failures
    WHERE topotest_failures.ci_job_id = ci_jobs.id
      AND topotest_failures.attempt = COALESCE(ci_jobs.retry, 0)
  )
SQL

CiJob
  .joins(:stage)
  .where(NO_FAILURES_FOR_CURRENT_ATTEMPT)
  .where("ci_jobs.name LIKE '%AddressSanitizer%'")
  .where(status: :failure)
  .where(stage: { status: :failure })
  .where('ci_jobs.created_at > ?', 6.month.ago)
  .each do |job|
  next if TopotestFailure.current_attempt_of(job).exists?

  failures = Github::TopotestFailures::RetrieveError.new(job).retrieve

  puts "Found #{failures.size} failures for job #{job.job_ref}"

  next if failures.empty?

  TopotestFailure.replace_for(job, failures)
end
