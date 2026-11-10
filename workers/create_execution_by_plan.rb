#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_plan.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

# Runs under Delayed Job, which retries the whole job when it raises. The job is split so a retry
# never repeats a Bamboo side effect:
#   1. GitHub authentication, before anything is written (an error here leaves nothing behind);
#   2. Bamboo: stop the previous build, start the new one;
#   3. GitHub checks (Github::Build::ChecksSetup). Errors here do not reach Delayed Job:
#      only this part is rescheduled, through .setup_github_checks.
class CreateExecutionByPlan
  GITHUB_SETUP_RETRY_DELAY = 30 # seconds

  def self.create(pull_request_id, payload, plan_id)
    logger = GithubLogger.instance.create('github_app.log', Logger::INFO)
    plan = Plan.find_by(id: plan_id)

    return [422, 'Plan not found'] if plan.nil?

    instance = new(pull_request_id, payload, plan_id)

    logger.info "CreateExecutionByPlan: Plan '#{plan.name}' for Pull Request ID: #{pull_request_id} with " \
                "status: #{instance.status.inspect}"

    instance.status
  end

  # GitHub-only part of an execution whose Bamboo plan has already started. Safe for Delayed Job to retry.
  def self.setup_github_checks(check_suite_id, plan_id, previous_check_suite_id, github_user_id)
    check_suite = CheckSuite.find_by(id: check_suite_id)
    plan = Plan.find_by(id: plan_id)

    return [404, 'Check Suite or Plan not found'] if check_suite.nil? or plan.nil?

    Github::Build::ChecksSetup
      .new(check_suite, plan,
           previous_check_suite: CheckSuite.find_by(id: previous_check_suite_id),
           github_user_id: github_user_id,
           resume: true)
      .run
  end

  attr_reader :status

  def initialize(pull_request_id, payload, plan_id)
    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO
    @app_logger = GithubLogger.instance.create('github_app.log', Logger::INFO)

    @pull_request = PullRequest.find(pull_request_id)
    @payload = payload
    @status = []

    create_execution_by_plan(Plan.find_by(id: plan_id))
  end

  private

  def create_execution_by_plan(plan)
    @logger.info "Starting Plan: #{plan.name}"

    fetch_last_check_suite(plan)

    build_check_suite(plan)

    return @status = [422, 'Failed to save Check Suite'] unless @check_suite.save

    @logger.info "Check Suite created: #{@check_suite.inspect}"

    # Stop a previous execution - Avoiding CI spam
    stop_previous_execution

    @logger.info "Starting a new execution for Pull Request: #{@pull_request.inspect}"
    status = start_new_execution(plan)

    @logger.info "New execution started with status: #{status}"

    return @status = [status, 'Failed to create CI Plan'] if status != 200

    @status = setup_github_checks(plan)
  end

  def setup_github_checks(plan)
    @logger.info 'Creating GitHub Check'

    Github::Build::ChecksSetup
      .new(@check_suite, plan, previous_check_suite: @previous_check_suite, github_user_id: github_user_id)
      .run
  rescue StandardError => e
    reschedule_github_checks(plan, e)
  end

  def reschedule_github_checks(plan, error)
    @app_logger.error "CreateExecutionByPlan: GitHub Checks setup failed for CheckSuite #{@check_suite.id} " \
                      "(#{@check_suite.bamboo_ci_ref}): #{error.class}: #{error.message} - rescheduling"

    CreateExecutionByPlan
      .delay(run_at: GITHUB_SETUP_RETRY_DELAY.seconds.from_now.utc, queue: 'create_execution_by_plan')
      .setup_github_checks(@check_suite.id, plan.id, @previous_check_suite&.id, github_user_id)

    [202, 'GitHub Checks setup rescheduled']
  end

  def start_new_execution(plan)
    @logger.info 'Starting a new plan'
    @bamboo_plan_run = BambooCi::PlanRun.new(@check_suite, plan, logger_level: @logger.level)
    @bamboo_plan_run.ci_variables = ci_vars
    @bamboo_plan_run.start_plan
  end

  # Only the Bamboo stop happens here. The GitHub side (cancelling the previous checks) is part of
  # ChecksSetup, so a GitHub error can no longer leave the previous build running.
  def stop_previous_execution
    return unless previous_execution_running?

    @logger.info 'Stopping previous execution'
    @logger.info @last_check_suite.inspect

    BambooCi::StopPlan.build(@last_check_suite.bamboo_ci_ref)

    @previous_check_suite = @last_check_suite
  end

  # An execution whose Bamboo build started but whose GitHub setup never created stages or jobs
  # is still running in Bamboo, even though it has nothing open in the database.
  def previous_execution_running?
    return false if @last_check_suite.nil?

    @last_check_suite.running? or (@last_check_suite.stages.empty? and @last_check_suite.ci_jobs.empty?)
  end

  # Check suites without a Bamboo reference never started a build, so they cannot be the previous execution.
  def fetch_last_check_suite(plan)
    @last_check_suite =
      CheckSuite
      .where(pull_request: @pull_request)
      .where(plan: [plan, nil])
      .where.not(bamboo_ci_ref: nil)
      .last
  end

  # GitHub authentication happens before the check suite is saved: if it fails, Delayed Job
  # retries the job and no orphan check suite is left behind.
  def build_check_suite(plan)
    @logger.info 'Creating a check suite'
    @check_suite =
      CheckSuite.new(
        pull_request: @pull_request,
        plan: plan,
        author: @payload.dig('pull_request', 'user', 'login'),
        commit_sha_ref: @payload.dig('pull_request', 'head', 'sha'),
        work_branch: @payload.dig('pull_request', 'head', 'ref'),
        base_sha_ref: @payload.dig('pull_request', 'base', 'sha'),
        merge_branch: @payload.dig('pull_request', 'base', 'ref')
      )

    @logger.info 'Creating GitHub Check API'
    @github_check = Github::Check.new(@check_suite)
  end

  def github_user_id
    @payload.dig('pull_request', 'user', 'id')
  end

  def ci_vars
    ci_vars = []
    ci_vars << { value: @github_check.signature, name: 'signature_secret' }

    ci_vars
  end
end
