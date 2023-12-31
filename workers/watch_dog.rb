#  SPDX-License-Identifier: BSD-2-Clause
#
#  watch_dog.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require_relative 'base'
require_relative '../lib/slack_bot/slack_bot'
require_relative '../lib/github/build/action'
require_relative '../lib/github/build/summary'

class WatchDog < Base
  def perform
    @logger = Logger.new('watch_dog.log', 0, 1_024_000)
    @logger.info '>>> Running watchdog'

    suites = check_suites

    @logger.info ">>> Suites that need to be updated: #{suites.size}"

    check(suites)

    @logger.info '>>> Stopping watchdog'
  end

  private

  def check(suites)
    suites.each do |check_suite|
      @logger.info ">>> CheckSuite: #{check_suite.inspect}"

      fetch_ci_execution(check_suite)
      build_status = fetch_build_status(check_suite)

      @logger.info ">>> Build status: #{build_status.inspect}"

      next if in_progress?(build_status)

      @logger.info ">>> Updating suite: #{check_suite.inspect}"
      check_stages(check_suite)
      clear_deleted_jobs(check_suite)
    end
  end

  # Checks if CI still running
  def in_progress?(build_status)
    return false if ci_stopped?(build_status)
    return false if ci_hanged?(build_status)

    true
  end

  def ci_stopped?(build_status)
    build_status.key?('message') and !build_status.key?('finished')
  end

  def ci_hanged?(build_status)
    return false if build_status.key?('message') and !build_status.key? 'finished'

    build_status.dig('progress', 'percentageCompleted').to_f >= 2.0
  end

  def check_suites
    CheckSuite.where(id: check_suites_fetch_map)
  end

  def check_suites_fetch_map
    CheckSuite
      .joins(:ci_jobs)
      .where(ci_jobs: { status: %w[queued in_progress] }, created_at: [..Time.now])
      .map(&:id)
      .uniq
  end

  # This method will move all tests that no longer exist in BambooCI to the skipped state,
  # because there are no executions for them.
  def clear_deleted_jobs(check_suite)
    github_check = Github::Check.new(check_suite)

    check_suite.ci_jobs.where(status: %w[queued in_progress]).each do |ci_job|
      ci_job.skipped(github_check)
    end
  end

  def check_stages(check_suite)
    github_check = Github::Check.new(check_suite)
    @result.dig('stages', 'stage').each do |stage|
      stage.dig('results', 'result').each do |result|
        ci_job = CiJob.find_by(job_ref: result['buildResultKey'], check_suite_id: check_suite.id)

        update_stage_status(ci_job, result, github_check)
      end
    end
  end

  def update_stage_status(ci_job, result, github)
    @logger.info ">>> CiJob: #{ci_job.inspect}}"
    return if ci_job.nil?
    return if ci_job.finished? && !ci_job.job_ref.nil?

    update_ci_job_status(github, ci_job, result['state'])
  end

  def update_ci_job_status(github_check, ci_job, state)
    ci_job.enqueue(github_check) if ci_job.job_ref.nil?

    output = create_output_message(ci_job)

    @logger.info ">>> CiJob: #{ci_job.inspect} updating status"
    case state
    when 'Unknown'
      ci_job.cancelled(github_check, output)
      slack_notify_cancelled(ci_job)
    when 'Failed'
      ci_job.failure(github_check, output)
      slack_notify_failure(ci_job)
    when 'Successful'
      ci_job.success(github_check, output)
      slack_notify_success(ci_job)
    else
      puts 'Ignored'
    end

    build_summary(ci_job)
  end

  def create_output_message(ci_job)
    url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"

    {
      title: ci_job.name,
      summary: "Details at [#{url}](#{url})\nUnfortunately we were unable to access the execution results."
    }
  end

  def build_summary(ci_job)
    summary = Github::Build::Summary.new(ci_job)
    summary.build_summary

    finished_execution?(ci_job.check_suite)
  end

  def finished_execution?(check_suite)
    return false unless current_execution?(check_suite)
    return false unless check_suite.finished?

    SlackBot.instance.execution_finished_notification(check_suite)
  end

  def current_execution?(check_suite)
    pull_request = check_suite.pull_request
    last_check_suite = pull_request.check_suites.reload.all.order(:created_at).last

    check_suite.id == last_check_suite.id
  end

  def fetch_subscriptions(notification, job)
    pull_request = job.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author], notification: notification)
      .uniq(&:slack_user_id)
  rescue StandardError
    []
  end

  def slack_notify_success(job)
    fetch_subscriptions(%w[all pass], job).each do |subscription|
      SlackBot.instance.notify_success(job, subscription)
    end
  end

  def slack_notify_failure(job)
    fetch_subscriptions(%w[all errors], job).each do |subscription|
      SlackBot.instance.notify_errors(job, subscription)
    end
  end

  def slack_notify_cancelled(job)
    fetch_subscriptions(%w[all errors], job).each do |subscription|
      SlackBot.instance.notify_cancelled(job, subscription)
    end
  end
end

watch_dog = WatchDog.new
watch_dog.perform
