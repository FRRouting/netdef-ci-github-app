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
  belongs_to :stage

  scope :sha256, ->(sha) { joins(:check_suite).where(check_suite: { commit_sha_ref: sha }) }
  scope :filter_by, ->(filter) { where('name ~ ?', filter) }
  scope :skip_stages, -> { where(is_stage: false) }
  scope :stages, -> { where(is_stage: true) }
  scope :skip_checkout_code, -> { where.not(name: 'Checkout Code') }
  scope :not_skipped, -> { where.not(status: 'skipped') }
  scope :failure, -> { where(status: %i[failure cancelled skipped]) }

  def checkout_code?
    name.downcase.match? 'checkout'
  end

  def build?
    name.downcase.match? 'build'
  end

  def test?
    !build? and !checkout_code?
  end

  def create_check_run
    update(status: :queued)
  end

  def enqueue(_github, _output = {})
    update(status: :queued)
  end

  def in_progress(github, output = {})
    unless check_ref.nil?
      create_github_check(github)
      github.in_progress(check_ref, output)
    end

    update(status: :in_progress)
  end

  def cancelled(github, output = {})
    unless check_ref.nil?
      create_github_check(github)
      github.cancelled(check_ref, output)
    end

    update(status: :cancelled)
  end

  def failure(github, output = {})
    unless check_ref.nil?
      create_github_check(github)
      github.failure(check_ref, output)
    end

    update(status: :failure)
  end

  def success(github, output = {})
    unless check_ref.nil?
      create_github_check(github)
      github.success(check_ref, output)
    end

    update(status: :success)
  end

  def skipped(github, output = {})
    unless check_ref.nil?
      create_github_check(github)
      github.skipped(check_ref, output)
    end

    update(status: :skipped)
  end

  private

  def create_github_check(github)
    return unless check_ref.nil?

    check_run = github.create(github_stage_full_name(name))
    update(check_ref: check_run.id)
  end
end
