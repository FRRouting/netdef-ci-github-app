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
  scope :filter_by, ->(filter) { where('name ~ ?', filter) }
  scope :skip_stages, -> { where(stage: false) }
  scope :stages, -> { where(stage: true) }
  scope :skip_checkout_code, -> { where.not(name: 'Checkout Code') }
  scope :not_skipped, -> { where.not(status: 'skipped') }

  def checkout_code?
    name.downcase.match? 'checkout'
  end

  def build?
    name.downcase.match? 'build'
  end

  def test?
    !build? and !checkout_code?
  end

  def finished?
    !%w[queued in_progress].include?(status.to_s)
  end

  def create_check_run
    update(status: :queued)
  end

  def enqueue(github, output = {})
    return update(status: :queued) unless stage

    github_check_run_name = checkout_code? ? Github::Build::Action::SOURCE_CODE : name

    count = 0
    begin
      check_run = github.create(github_check_run_name)
      github.queued(check_run.id, output)
      update(check_ref: check_run.id, status: :queued)
    rescue StandardError
      count += 1
      sleep 1

      retry if count <= 5
    end
  end

  def in_progress(github, output = {})
    return update(status: :in_progress) unless stage

    create_github_check(github)
    github.in_progress(check_ref, output)
    update(status: :in_progress)
  end

  def cancelled(github, output = {})
    return update(status: :cancelled) unless stage

    create_github_check(github)

    github.cancelled(check_ref, output)

    update(status: :cancelled)
  end

  def failure(github, output = {})
    return update(status: :failure) unless stage

    create_github_check(github)
    github.failure(check_ref, output)
    update(status: :failure)
  end

  def success(github, output = {})
    return update(status: :success) unless stage

    create_github_check(github)
    github.success(check_ref, output)
    update(status: :success)
  end

  private

  def create_github_check(github)
    return unless check_ref.nil?

    github_check_run_name = checkout_code? ? Github::Build::Action::SOURCE_CODE : name

    check_run = github.create(github_check_run_name)
    update(check_ref: check_run.id)
  end
end
