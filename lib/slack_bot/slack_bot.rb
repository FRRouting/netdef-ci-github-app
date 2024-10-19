# frozen_string_literal: true

require 'logger'
require 'net/http'
require 'net/https'
require 'singleton'

require_relative '../../database_loader'
require_relative '../helpers/request'

class SlackBot
  include Singleton
  include GitHubApp::Request

  def initialize
    @logger_manager = []

    @logger_manager << GithubLogger.instance.create('github_app.log', Logger::WARN)
    @logger_manager << GithubLogger.instance.create('github_retry.log', Logger::INFO)
  end

  def find_user_id_by_name(username)
    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/translate/#{username}"
    get_request(URI(url), json: false)
  end

  def invalid_rerun_group(job)
    return unless current_execution?(job.check_suite)

    reason = invalid_rerun_message(job)

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/comment"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: reason)

    reason
  end

  def invalid_rerun_dm(job, subscription)
    return unless current_execution?(job.check_suite)

    reason = invalid_rerun_message(job)

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: { message: reason, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def notify_errors(job)
    return unless current_execution?(job.check_suite)

    message = generate_notification_message(job, 'Failed')
    pull_request = job.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author], notification: %w[all errors])
      .uniq(&:slack_user_id).each do |subscription|
      send_error_message(message, subscription)
    end
  end

  def notify_cancelled(job)
    return unless current_execution?(job.check_suite)

    message = generate_notification_message(job, 'Failed')
    pull_request = job.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author], notification: %w[all errors])
      .uniq(&:slack_user_id).each do |subscription|
      send_cancel_message(message, subscription)
    end
  end

  def notify_success(job)
    return unless current_execution?(job.check_suite)

    pull_request = job.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, job.check_suite.pull_request.author], notification: %w[all pass])
      .uniq(&:slack_user_id).each do |subscription|
      send_success_message(job, subscription)
    end
  end

  def execution_started_notification(check_suite)
    return unless current_execution?(check_suite)

    PullRequestSubscription
      .where(target: [check_suite.pull_request.github_pr_id, check_suite.pull_request.author])
      .uniq(&:slack_user_id)
      .each do |subscription|
      started_finished_notification(check_suite, subscription)
    end
  end

  def execution_finished_notification(check_suite)
    return unless current_execution?(check_suite)

    pull_request = check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author])
      .uniq(&:slack_user_id)
      .each do |subscription|
      started_finished_notification(check_suite, subscription, started_or_finished: 'Finished')
    end
  end

  def stage_finished_notification(stage)
    return unless current_execution?(stage.check_suite)

    pull_request = stage.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author])
      .uniq(&:slack_user_id)
      .each do |subscription|
      send_stage_notification(stage.reload, pull_request, subscription)
    end
  end

  def stage_in_progress_notification(stage)
    return unless current_execution?(stage.check_suite)

    pull_request = stage.check_suite.pull_request

    PullRequestSubscription
      .where(target: [pull_request.github_pr_id, pull_request.author])
      .uniq(&:slack_user_id)
      .each do |subscription|
      send_stage_notification(stage.reload, pull_request, subscription)
    end
  end

  private

  def current_execution?(check_suite)
    pull_request = check_suite.pull_request
    current_check_suite = pull_request.check_suites.last

    check_suite.id >= current_check_suite&.id.to_i
  end

  def send_stage_notification(stage, pull_request, subscription)
    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"

    pr_url = "https://github.com/#{pull_request.repository}/pull/#{pull_request.github_pr_id}"
    bamboo_link = "https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"

    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: {
                   message: "PR <#{pr_url}|##{pull_request.github_pr_id}>. " \
                            "Stage: <#{bamboo_link}|[CI] #{stage.name} - #{stage.status}> ",
                   slack_user_id: subscription.slack_user_id
                 }.to_json)
  end

  def send_success_message(job, subscription)
    message = generate_notification_message(job, 'Success')

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: { message: message, unfurl_links: false, unfurl_media: false,
                         slack_user_id: subscription.slack_user_id }.to_json)
  end

  def send_error_message(message, subscription)
    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def send_cancel_message(message, subscription)
    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def started_finished_notification(check_suite, subscription, started_or_finished: 'Started')
    message = pull_request_message(check_suite, started_or_finished)

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url),
                 machine: 'slack_bot.netdef.org',
                 body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def pull_request_message(check_suite, status)
    pr = check_suite.pull_request

    pr_url = "https://github.com/#{pr.repository}/pull/#{pr.github_pr_id}"
    bamboo_link = "https://ci1.netdef.org/browse/#{check_suite.bamboo_ci_ref}"

    "PR <#{pr_url}|##{pr.github_pr_id}>. <#{bamboo_link}|#{status}> "
  end

  def generate_notification_message(job, status)
    pr = job.check_suite.pull_request
    pr_url = "https://github.com/#{pr.repository}/pull/#{pr.github_pr_id}/checks?check_run_id=#{job.check_ref}"
    bamboo_link = "https://ci1.netdef.org/browse/#{job.job_ref}"

    "PR <#{pr_url}|##{pr.github_pr_id}>. <#{bamboo_link}|#{job.name} - #{status}> "
  end

  def logger(severity, message)
    @logger_manager.each do |logger_object|
      logger_object.add(severity, message)
    end
  end

  def invalid_rerun_message(job)
    pr = job.check_suite.pull_request
    pr_url = "https://github.com/#{pr.repository}/pull/#{pr.github_pr_id}"
    reason =
      "PR <#{pr_url}|##{pr.github_pr_id}> tried to perform a partial rerun, but there were still tests running."

    logger(Logger::INFO, "enqueued - #{job.inspect} Reason: #{reason}")

    reason
  end
end
