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
  has_many :plans
  def finished?
    last_suite = check_suites.last
    return true if check_suites.blank? or last_suite.blank?

    return plans.all? { |p| current_execution_by_plan(p)&.finished? } if plans.any?

    last_suite.finished?
  end

  def current_execution?(check_suite)
    current_execution_by_plan(check_suite.plan) == check_suite
  end

  def current_execution_by_plan(plan_obj)
    check_suites.where(plan: plan_obj).order(id: :asc).last
  end

  def self.unique_repository_names
    distinct.pluck(:repository)
  end
end
