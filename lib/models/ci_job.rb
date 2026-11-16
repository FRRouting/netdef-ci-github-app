#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'
require_relative '../helpers/prometheus_metrics'

class CiJob < ActiveRecord::Base
  enum :status, { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }

  validates :name, presence: true
  validates :job_ref, presence: true

  has_many :topotest_failures, dependent: :delete_all
  has_many :audit_statuses, as: :auditable
  has_and_belongs_to_many :audit_retries
  belongs_to :stage
  belongs_to :check_suite

  scope :sha256, ->(sha) { joins(:check_suite).where(check_suite: { commit_sha_ref: sha }) }
  scope :filter_by, ->(filter) { where('name ~ ?', filter) }
  scope :skip_stages, -> { where(is_stage: false) }
  scope :stages, -> { where(is_stage: true) }
  scope :skip_checkout_code, -> { where.not(name: 'Checkout Code') }
  scope :not_skipped, -> { where.not(status: 'skipped') }
  # Not named `failure`: that would silently replace the enum scope (status = failure only)
  scope :unsuccessful, -> { where(status: %i[failure cancelled skipped]) }

  default_scope -> { order(id: :asc) }, all_queries: true

  def checkout_code?
    name.match(/checkout/i)
  end

  def finished?
    !%w[queued in_progress].include?(status)
  end

  def update_execution_time
    finished = last_audit_status(%i[success failure])
    return if finished.nil?

    started = last_audit_status(:in_progress, until_time: finished.created_at)
    return if started.nil?

    duration = finished.created_at - started.created_at
    update(execution_time: duration)

    stage_name = stage&.configuration&.bamboo_stage_name || 'unknown'
    PrometheusMetrics::CI_JOB_DURATION.observe(duration, labels: { stage: stage_name, status: status })
  end

  def create_check_run(agent: 'Github')
    AuditStatus.create(auditable: self, status: :queued, agent: agent, created_at: Time.now)
    update(status: :queued)
  end

  def enqueue(_github, _output = {}, agent: 'Github')
    AuditStatus.create(auditable: self, status: :queued, agent: agent, created_at: Time.now)
    update(status: :queued)
  end

  def in_progress(github, output: {}, agent: 'Github')
    github.in_progress(check_ref, output) unless check_ref.nil?

    AuditStatus.create(auditable: self, status: :in_progress, agent: agent, created_at: Time.now)
    update(status: :in_progress)
  end

  def cancelled(github, output: {}, agent: 'Github')
    github.cancelled(check_ref, output) unless check_ref.nil?

    AuditStatus.create(auditable: self, status: :cancelled, agent: agent, created_at: Time.now)
    update(status: :cancelled)
  end

  def failure(github, output: {}, agent: 'Github')
    github.failure(check_ref, output) unless check_ref.nil?

    AuditStatus.create(auditable: self, status: :failure, agent: agent, created_at: Time.now)
    update(status: :failure)
  end

  def success(github, output: {}, agent: 'Github')
    github.success(check_ref, output) unless check_ref.nil?

    AuditStatus.create(auditable: self, status: :success, agent: agent, created_at: Time.now)
    update(status: :success)
  end

  def skipped(github, output: {}, agent: 'Github')
    github.skipped(check_ref, output) unless check_ref.nil?

    AuditStatus.create(auditable: self, status: :skipped, agent: agent, created_at: Time.now)
    update(status: :skipped)
  end

  private

  # A retried job has several audit entries: pair the latest finish with the start that preceded it
  def last_audit_status(status, until_time: nil)
    scope = audit_statuses.where(status: status)
    scope = scope.where(created_at: ..until_time) unless until_time.nil?
    scope.order(:created_at, :id).last
  end
end
