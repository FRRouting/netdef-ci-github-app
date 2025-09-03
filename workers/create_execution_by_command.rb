#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_command.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

class CreateExecutionByCommand < Github::ReRun::Base
  def self.create(plan_id, check_suite_id)
    check_suite = CheckSuite.find(check_suite_id)
    plan = Plan.find(plan_id)

    return [404, 'Failed to fetch a check suite'] if check_suite.nil?

    @github_check = Github::Check.new(check_suite)

    stop_previous_execution(plan)

    check_suite = create_check_suite(check_suite)

    start_new_execution(check_suite, plan)
    ci_jobs(check_suite, plan)
  end
end
