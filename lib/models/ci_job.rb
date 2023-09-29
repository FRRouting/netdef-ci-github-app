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

  belongs_to :check_suite
  has_many :topotest_failures, dependent: :delete_all

  scope :sha256, ->(sha) { joins(:check_suite).where(check_suite: { commit_sha_ref: sha }) }

  def checkout_code?
    name.downcase.match? 'checkout'
  end

  def finished?
    !%w[queued in_progress].include?(status.to_s)
  end

  def create_check_run
    update(status: :queued)
  end

  def enqueue(github)
    check_run = github.create(name)
    update(check_ref: check_run.id, status: :queued)
  end

  def in_progress(github, output = {})
    check_run = save_check_run(github)
    github.in_progress(check_run.id, output)

    update(check_ref: check_run.id, status: :in_progress)
  end

  def cancelled(github, output = {})
    github.cancelled(check_ref, output)

    update(status: :cancelled)
  end

  def failure(github, output = {})
    github.failure(check_ref, output)

    update(status: :failure)
  end

  def success(github, output = {})
    github.success(check_ref, output)

    update(status: :success)
  end

  def skipped(github, output = {})
    github.skipped(check_ref, output)

    update(status: :skipped)
  end

  private

  def save_check_run(github)
    github.create(name)
  end
end
