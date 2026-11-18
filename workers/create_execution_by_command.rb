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
  def self.create(plan_id, check_suite_id, payload)
    check_suite = CheckSuite.find(check_suite_id)
    plan = Plan.find(plan_id)

    return [404, 'Failed to fetch a check suite'] if check_suite.nil?

    instance = new(plan, check_suite, payload)

    instance.status
  end

  QUEUE = 'create_execution_by_command'

  attr_reader :status

  def initialize(plan, check_suite, payload)
    super(payload, logger_level: Logger::INFO)

    @logger_manager << GithubLogger.instance.create('github_rerun_command.log', Logger::INFO)
    @logger_manager << Logger.new($stdout)

    @github_check = Github::Check.new(check_suite)
    @pull_request = check_suite.pull_request

    @status = release_claim_on_failure { start_by_plan(plan, check_suite) }
  end

  private

  def start_by_plan(plan, check_suite)
    stop_previous_execution(plan)

    new_check_suite = create_check_suite(check_suite, plan)

    start_new_execution(new_check_suite, plan)
    return [@plan_status, 'Failed to create CI Plan'] if @plan_status != 200

    setup_github_checks(new_check_suite, plan)

    [201, 'Starting re-run (command)']
  end

  def create_check_suite(check_suite, plan)
    CheckSuite.create(
      pull_request: check_suite.pull_request,
      plan: plan,
      author: check_suite.author,
      commit_sha_ref: check_suite.commit_sha_ref,
      work_branch: check_suite.work_branch,
      base_sha_ref: check_suite.base_sha_ref,
      merge_branch: check_suite.merge_branch,
      re_run: true
    )
  end
end
