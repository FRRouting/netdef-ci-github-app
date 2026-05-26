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
    check_suite = CheckSuite.find_by(id: check_suite_id)
    plan = Plan.find_by(id: plan_id)

    return [404, 'Failed to fetch a check suite'] if check_suite.nil?
    return [404, 'Plan not found'] if plan.nil?

    instance = new(plan, check_suite, payload)

    instance.status
  end

  attr_reader :status

  def initialize(plan, check_suite, payload)
    super(payload, logger_level: Logger::INFO)

    @logger_manager << GithubLogger.instance.create('github_rerun_command.log', Logger::INFO)
    @logger_manager << Logger.new($stdout)

    @github_check = Github::Check.new(check_suite)

    stop_previous_execution(plan)

    check_suite = create_check_suite(check_suite, plan)

    unless check_suite.persisted?
      @status = [422, 'Failed to save Check Suite']
      return
    end

    bamboo_status = start_new_execution(check_suite, plan)

    unless bamboo_status == 200
      @status = [bamboo_status, 'Failed to create CI Plan']
      return
    end

    ci_jobs(check_suite, plan)
    @status = [200, 'Scheduled Plan Runs']
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

  def start_new_execution(check_suite, plan)
    cleanup(check_suite)

    bamboo_plan_run = BambooCi::PlanRun.new(check_suite, plan, logger_level: @logger_level)
    bamboo_plan_run.ci_variables = ci_vars
    status = bamboo_plan_run.start_plan

    audit_retry =
      AuditRetry.create(check_suite: check_suite,
                        github_username: @payload.dig('sender', 'login'),
                        github_id: @payload.dig('sender', 'id'),
                        github_type: @payload.dig('sender', 'type'),
                        retry_type: 'full')

    Github::UserInfo.new(@payload.dig('sender', 'id'), check_suite: check_suite, audit_retry: audit_retry)

    status
  end
end
