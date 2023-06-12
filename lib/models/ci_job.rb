# frozen_string_literal: true

require 'otr-activerecord'

class CiJob < ActiveRecord::Base
  enum status: { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }

  validates :name, presence: true
  validates :job_ref, presence: true

  belongs_to :check_suite

  scope :sha256, ->(sha) { joins(:check_suite).where(check_suite: { commit_sha_ref: sha }) }

  def create_check_run(github)
    check_run = github.create(name)

    update(check_ref: check_run.id, status: :queued)
  end

  def enqueue(github)
    create_check_run(github)
  end

  def in_progress(github)
    github.in_progress(check_ref)

    update(status: :in_progress)
  end

  def cancelled(github)
    github.cancelled(check_ref)

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

  def skipped(github)
    github.skipped(check_ref)

    update(status: :skipped)
  end
end
