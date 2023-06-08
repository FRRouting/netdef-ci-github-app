# frozen_string_literal: true

require 'otr-activerecord'

class CheckSuite < ActiveRecord::Base
  validates :author, presence: true
  validates :commit_sha_ref, presence: true
  validates :bamboo_ci_ref

  belongs_to :pull_request
  has_many :ci_jobs

  def finished?
    ci_jobs.find_by_status(0..1).nil?
  end
end
