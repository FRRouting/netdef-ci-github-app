#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_plan.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

class CreateExecutionByPlan
  CHECKS_SETUP_RETRY_DELAY = 10 # seconds

  # GitHub-only retry of a failed Checks setup. Delayed Job may retry this one freely:
  # it never creates a CheckSuite and never starts or stops a Bamboo plan.
  def self.setup_github_checks(check_suite_id, plan_id, last_check_suite_id)
    Github::Build::ChecksSetup.new(
      CheckSuite.find(check_suite_id),
      Plan.find(plan_id),
      last_check_suite: CheckSuite.find_by(id: last_check_suite_id),
      resume: true
    ).run
  end

  def self.create(pull_request_id, payload, plan_id)
    logger = GithubLogger.instance.create('github_app.log', Logger::INFO)
    plan = Plan.find_by(id: plan_id)

    return [422, 'Plan not found'] if plan.nil?

    instance = new(pull_request_id, payload, plan_id)

    logger.info "CreateExecutionByPlan: Plan '#{plan.name}' for Pull Request ID: #{pull_request_id} with " \
                "status: #{instance.status.inspect}"

    instance.status
  end

  attr_reader :status

  def initialize(pull_request_id, payload, plan_id)
    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO

    @pull_request = PullRequest.find(pull_request_id)
    @payload = payload
    @status = []

    create_execution_by_plan(Plan.find_by(id: plan_id))
  end

  private

  def create_execution_by_plan(plan)
    @has_previous_exec = false

    @logger.info "Starting Plan: #{plan.name}"

    fetch_last_check_suite(plan)

    create_check_suite

    unless @check_suite.persisted?
      @status = [422, 'Failed to save Check Suite']

      return
    end

    @check_suite.update(plan: plan)

    @logger.info "Check Suite created: #{@check_suite.inspect}"

    # Stop a previous execution - Avoiding CI spam
    stop_previous_execution

    @logger.info "Starting a new execution for Pull Request: #{@pull_request.inspect}"
    # Starting a new CI run
    status = start_new_execution(plan)

    @logger.info "New execution started with status: #{status}"

    if status != 200
      @status = [status, 'Failed to create CI Plan']

      return
    end

    @status = ci_jobs(plan)
  end

  def ci_jobs(plan)
    @logger.info 'Creating GitHub Check'

    SlackBot.instance.execution_started_notification(@check_suite)

    @logger.info ">>> @has_previous_exec: #{@has_previous_exec}"

    Github::Build::ChecksSetup
      .new(@check_suite, plan, github_check: @github_check, last_check_suite: previous_check_suite)
      .run
  rescue StandardError => e
    reschedule_checks_setup(plan, e)
  end

  # The Bamboo plan is already running at this point. If the error reached Delayed Job,
  # it would re-run this whole job: create another CheckSuite, stop the plan we just
  # started (often still in "Checkout Code" -> "Failed to prepare the build") and start
  # yet another one. Retry only the GitHub side instead.
  def reschedule_checks_setup(plan, error)
    GithubLogger.instance.create('github_app.log', Logger::INFO)
                .error("CreateExecutionByPlan: GitHub Checks setup failed for CheckSuite #{@check_suite.id} " \
                       "(#{error.class}: #{error.message}) - rescheduling GitHub-only setup")

    CreateExecutionByPlan
      .delay(run_at: CHECKS_SETUP_RETRY_DELAY.seconds.from_now.utc, queue: 'create_execution_by_plan')
      .setup_github_checks(@check_suite.id, plan.id, previous_check_suite&.id)

    [202, 'GitHub Checks setup rescheduled']
  end

  def previous_check_suite
    @has_previous_exec ? @last_check_suite : nil
  end

  def start_new_execution(plan)
    @check_suite.pull_request = @pull_request

    Github::UserInfo.new(@payload.dig('pull_request', 'user', 'id'), check_suite: @check_suite)

    @logger.info 'Starting a new plan'
    @bamboo_plan_run = BambooCi::PlanRun.new(@check_suite, plan, logger_level: @logger.level)
    @bamboo_plan_run.ci_variables = ci_vars
    @bamboo_plan_run.start_plan
  end

  def stop_previous_execution
    return if @last_check_suite.nil? or @last_check_suite.finished?

    @logger.info 'Stopping previous execution'
    @logger.info @last_check_suite.inspect
    @logger.info @check_suite.inspect

    cancel_previous_ci_jobs
  end

  def cancel_previous_ci_jobs
    mark_as_cancelled_jobs

    @last_check_suite.update(stopped_in_stage: @last_check_suite.stages.where(status: :in_progress).last)

    mark_as_cancelled_stages

    @has_previous_exec = true

    BambooCi::StopPlan.build(@last_check_suite.bamboo_ci_ref)
  end

  def mark_as_cancelled_jobs
    @last_check_suite.ci_jobs.where(status: %w[queued in_progress]).each do |ci_job|
      @logger.warn("Cancelling Job #{ci_job.inspect}")
      ci_job.cancelled(@github_check)
    end
  end

  def mark_as_cancelled_stages
    @last_check_suite.stages.where(status: %w[queued in_progress]).each do |stage|
      stage.cancelled(@github_check)
    end
  end

  def fetch_last_check_suite(plan)
    @last_check_suite =
      CheckSuite
      .where(pull_request: @pull_request)
      .where(plan: [plan, nil])
      .last
  end

  def create_check_suite
    @logger.info 'Creating a check suite'
    @check_suite =
      CheckSuite.create(
        pull_request: @pull_request,
        author: @payload.dig('pull_request', 'user', 'login'),
        commit_sha_ref: @payload.dig('pull_request', 'head', 'sha'),
        work_branch: @payload.dig('pull_request', 'head', 'ref'),
        base_sha_ref: @payload.dig('pull_request', 'base', 'sha'),
        merge_branch: @payload.dig('pull_request', 'base', 'ref')
      )

    @logger.info 'Creating GitHub Check API'
    @github_check = Github::Check.new(@check_suite)
  end

  def ci_vars
    ci_vars = []
    ci_vars << { value: @github_check.signature, name: 'signature_secret' }

    ci_vars
  end
end
