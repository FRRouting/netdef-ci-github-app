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


CiJob
  .where("ci_jobs.name LIKE '%AddressSanitizer%'")
  .where(status: :failure)
  .each do |job|
  next if job.topotest_failures.any?

  CiJob.transaction do
    failures = Github::TopotestFailures::RetrieveError.new(job).retrieve

    next if failures.empty?

    failures.each do |failure|
      TopotestFailure.create(ci_job: job,
                             test_suite: failure['suite'],
                             test_case: failure['case'],
                             message: failure['message'],
                             execution_time: failure['execution_time'])
    end
  end
end

