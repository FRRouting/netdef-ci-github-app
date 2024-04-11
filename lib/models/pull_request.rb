#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class PullRequest < ActiveRecord::Base
  validates :author, presence: true
  validates :github_pr_id, presence: true
  validates :branch_name, presence: true
  validates :repository, presence: true

  has_many :check_suites, dependent: :delete_all
  has_many :pull_request_subscriptions, dependent: :delete_all

  def new?
    check_suites.nil? or check_suites.empty?
  end

  def finished?
    return true if new?

    current_execution&.finished?
  end

  def current_execution?(check_suite)
    current_execution == check_suite
  end

  def current_execution
    check_suites.max_by(&:id)
  end
end
