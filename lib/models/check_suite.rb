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

  belongs_to :stopped_in_stage, class_name: 'Stage', optional: true
  belongs_to :cancelled_previous_check_suite, class_name: 'CheckSuite', optional: true

  has_many :ci_jobs, dependent: :delete_all
  has_many :stages, dependent: :delete_all
  has_many :audit_retries, dependent: :delete_all

  default_scope -> { order(id: :asc) }, all_queries: true

  def stages_failure
    stages.joins(:jobs).where(jobs: { status: %w[cancelled failure] }).all.uniq
  end

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

  def last_job_updated_at_timer
    ci_jobs.max_by(&:updated_at).to_s.updated_at
  end
end
