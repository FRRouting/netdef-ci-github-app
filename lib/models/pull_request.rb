# frozen_string_literal: true

require 'otr-activerecord'

class PullRequest < ActiveRecord::Base
  validates :author, presence: true
  validates :github_pr_id, presence: true
  validates :branch_name, presence: true
  validates :repository, presence: true

  has_many :check_suites

  def new?
    check_suites.nil? or check_suites.empty?
  end

  def finished?
    check_suites.last.finished?
  end
end
