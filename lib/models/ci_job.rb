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

class CiJob < ActiveRecord::Base
  enum status: { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }

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
  scope :failure, -> { where(status: %i[failure cancelled skipped]) }

  def finished?
    !%w[queued in_progress].include?(status)
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
    unless check_ref.nil?
      create_github_check(github)
      github.in_progress(check_ref, output)
    end

    AuditStatus.create(auditable: self, status: :in_progress, agent: agent, created_at: Time.now)
    update(status: :in_progress)
  end

  def cancelled(github, output: {}, agent: 'Github')
    unless check_ref.nil?
      create_github_check(github)
      github.cancelled(check_ref, output)
    end

    AuditStatus.create(auditable: self, status: :cancelled, agent: agent, created_at: Time.now)
    update(status: :cancelled)
  end

  def failure(github, output: {}, agent: 'Github')
    unless check_ref.nil?
      create_github_check(github)
      github.failure(check_ref, output)
    end

    AuditStatus.create(auditable: self, status: :failure, agent: agent, created_at: Time.now)
    update(status: :failure)
  end

  def success(github, output: {}, agent: 'Github')
    unless check_ref.nil?
      create_github_check(github)
      github.success(check_ref, output)
    end

    AuditStatus.create(auditable: self, status: :success, agent: agent, created_at: Time.now)
    update(status: :success)
  end

  def skipped(github, output: {}, agent: 'Github')
    unless check_ref.nil?
      create_github_check(github)
      github.skipped(check_ref, output)
    end

    AuditStatus.create(auditable: self, status: :skipped, agent: agent, created_at: Time.now)
    update(status: :skipped)
  end

  private

  def create_github_check(github)
    return unless check_ref.nil?

    check_run = github.create(github_stage_full_name(name))
    update(check_ref: check_run.id)
  end
end
