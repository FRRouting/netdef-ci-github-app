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

    logger_app = Logger.new('github_app.log', 1, 1_024_000)
    logger_app.level = Logger::WARN

    logger_class = Logger.new('github_retry.log', 0, 1_024_000)
    logger_class.level = Logger::INFO

    @logger_manager << logger_app
    @logger_manager << logger_class
  end

  def invalid_rerun_group(job)
    reason = invalid_rerun_message(job)

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/comment"
    post_request(URI(url), body: reason)

    reason
  end

  def invalid_rerun_dm(job, subscription)
    reason = invalid_rerun_message(job)

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url), body: { message: reason, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def notify_in_progress(job, subscription)
    message = generate_notification_message(job, 'In Progress')

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url), body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def notify_errors(job, subscription)
    message = generate_notification_message(job, 'Failed')

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url), body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def notify_cancelled(job, subscription)
    message = generate_notification_message(job, 'Cancelled')

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url), body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  def notify_success(job, subscription)
    message = generate_notification_message(job, 'Success')

    url = "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user"
    post_request(URI(url), body: { message: message, slack_user_id: subscription.slack_user_id }.to_json)
  end

  private

  def generate_notification_message(job, status)
    pr = job.check_suite.pull_request
    pr_url = "https://github.com/#{pr.repository}/pull/#{pr.github_pr_id}"
    bamboo_link = "https://ci1.netdef.org/browse/#{job.job_ref}"

    "PR <#{pr_url}|##{pr.github_pr_id}>. <#{bamboo_link}|#{job.name} - #{status}> "
  end

  def fetch_user_pass
    netrc = Netrc.read
    netrc['slack_bot.netdef.org']
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
