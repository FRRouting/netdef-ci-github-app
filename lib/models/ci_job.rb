# frozen_string_literal: true

require 'otr-activerecord'

class CiJob < ActiveRecord::Base
  enum status: %i[queued in_progress success failed]

  validates :author, presence: true
  validates :github_pr_id, presence: true
  validates :branch_name, presence: true
  validates :repository, presence: true

  has_many :check_suites
end
