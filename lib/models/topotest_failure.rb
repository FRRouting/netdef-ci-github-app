#  SPDX-License-Identifier: BSD-2-Clause
#
#  topotest_failure.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class TopotestFailure < ActiveRecord::Base
  belongs_to :ci_job

  scope :current_attempt_of, ->(ci_job) { where(ci_job: ci_job, attempt: ci_job.retry.to_i) }

  # Bamboo may report the same failures more than once (callback redelivery, refetch): the latest report
  # replaces the previous one of the same attempt. Earlier attempts (partial retries reuse the CiJob) are kept.
  def self.replace_for(ci_job, failures, attempt: ci_job.retry.to_i)
    transaction do
      where(ci_job: ci_job, attempt: attempt).delete_all

      failures.each do |failure|
        create(ci_job: ci_job,
               attempt: attempt,
               test_suite: failure['suite'],
               test_case: failure['case'],
               message: failure['message'],
               execution_time: failure['execution_time'])
      end
    end
  end

  def to_h
    {
      'suite' => test_suite,
      'case' => test_case,
      'message' => message,
      'execution_time' => execution_time
    }
  end
end
