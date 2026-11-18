#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class Plan < ActiveRecord::Base
  has_many :check_suites

  belongs_to :pull_request

  # Plan ids a check suite of this plan may carry. Suites created before plans were recorded on them have
  # none; they can only be told apart when the repository has a single plan, otherwise a suite of another
  # plan could be taken for one of this plan.
  def suite_plan_ids
    Plan.where(github_repo_name: github_repo_name).count > 1 ? [id] : [id, nil]
  end
end
