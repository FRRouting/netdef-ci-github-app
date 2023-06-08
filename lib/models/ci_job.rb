# frozen_string_literal: true

require 'otr-activerecord'

class CiJob < ActiveRecord::Base
  enum status: { queued: 0, in_progress: 1, success: 2, cancelled: -1, failed: -2 }

  validates :name, presence: true
  validates :job_ref, presence: true

  belongs_to :check_suite

  def create_check_run(github)
    check_run = github.create(name)

    update(check_ref: check_run.id)
  end

  def cancelled(github)
    github.cancelled(check_ref)

    update(status: :cancelled)
  end
end
