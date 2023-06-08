# frozen_string_literal: true

require 'otr-activerecord'

class CheckSuite < ActiveRecord::Base
  validates :author, presence: true
  validates :commit_sha_ref, presence: true

  belongs_to :pull_request
  has_many :ci_jobs, dependent: :delete_all

  def finished?
    ci_jobs.find_by_status(%i[queued in_progress]).nil?
  end
end
