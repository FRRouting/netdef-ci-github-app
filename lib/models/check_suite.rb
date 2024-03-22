#  SPDX-License-Identifier: BSD-2-Clause
#
#  check_suite.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class CheckSuite < ActiveRecord::Base
  validates :author, presence: true
  validates :commit_sha_ref, presence: true

  belongs_to :pull_request
  has_many :ci_jobs, dependent: :delete_all
  has_many :stages, dependent: :delete_all
  has_many :audit_retries, dependent: :delete_all

  def finished?
    !running?
  end

  def running?
    stages.where(status: %i[queued in_progress]).any?
  end

  def running_jobs
    ci_jobs.where(status: %i[queued in_progress])
  end

  def in_progress?
    !finished?
  end

  def execution_started?
    ci_jobs.where(status: :in_progress).size < 2
  end
end
