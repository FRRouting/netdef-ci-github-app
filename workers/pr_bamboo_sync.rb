#  SPDX-License-Identifier: BSD-2-Clause
#
#  pr_bamboo_sync.rb
#  Part of NetDEF CI System
#
#  Starting from GitHub Actions as source of truth:
#  1. Lists open PRs updated within the 24h-2h window for each known repository
#  2. Fetches active (in_progress / queued) GitHub check runs per PR
#  3. Validates the corresponding Bamboo CI execution status
#  4. Syncs stale check suites (GitHub active but Bamboo done)
#
#  Usage (run from project root):
#    RACK_ENV=production ruby workers/pr_bamboo_sync.rb
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require_relative '../config/setup'

class PrBambooSync
  include BambooCi::Api

  WINDOW_START_HOURS = 24
  WINDOW_END_HOURS   = 2

  def perform
    @logger = GithubLogger.instance.create('pr_bamboo_sync.log', Logger::INFO)
    @logger.info '>>> PrBambooSync: starting'

    time_start = WINDOW_START_HOURS.hours.ago
    time_end   = WINDOW_END_HOURS.hours.ago
    log_and_print "Time window: #{time_start} .. #{time_end}"

    results = PullRequest.unique_repository_names.flat_map do |repo|
      process_repository(repo, time_start, time_end)
    end

    print_report(results)
    @logger.info '>>> PrBambooSync: done'
  end

  private

  def process_repository(repo, time_start, time_end)
    github = github_client_for(repo)
    return [] if github.nil?

    prs = fetch_prs_in_window(github, repo, time_start, time_end)
    log_and_print "\n#{repo}: #{prs.size} open PR(s) with activity in window"

    prs.flat_map { |pr| process_pr(github, repo, pr) }
  end

  def github_client_for(repo)
    suite = CheckSuite.joins(:pull_request)
                      .where(pull_requests: { repository: repo })
                      .last
    Github::Check.new(suite)
  rescue StandardError => e
    @logger.error "Cannot build GitHub client for #{repo}: #{e.message}"
    nil
  end

  def fetch_prs_in_window(github, repo, time_start, time_end)
    github.app.pull_requests(repo, state: 'open', per_page: 100).select do |pr|
      pr[:updated_at].between?(time_start, time_end)
    end
  rescue StandardError => e
    @logger.error "Failed to fetch PRs for #{repo}: #{e.message}"
    []
  end

  def process_pr(github, repo, pr_object)
    sha         = pr_object.dig(:head, :sha)
    active_runs = fetch_active_github_runs(github, repo, sha)
    return [] if active_runs.empty?

    log_and_print "  PR ##{pr_object[:number]} SHA=#{sha[0..7]}: #{active_runs.size} active GitHub run(s)"

    find_check_suites(repo, pr_object[:number], sha).map { |cs| validate_suite(cs, active_runs.size) }
  end

  def fetch_active_github_runs(github, repo, sha)
    in_progress = github.check_runs_for_ref(repo, sha, status: 'in_progress')
    queued      = github.check_runs_for_ref(repo, sha, status: 'queued')

    Array(in_progress[:check_runs]) + Array(queued[:check_runs])
  rescue StandardError => e
    @logger.error "    Failed fetching GitHub runs for #{sha[0..7]}: #{e.message}"
    []
  end

  def find_check_suites(repo, pr_number, sha)
    CheckSuite
      .joins(:pull_request)
      .where(pull_requests: { github_pr_id: pr_number, repository: repo }, commit_sha_ref: sha)
      .includes(:pull_request)
  end

  def validate_suite(check_suite, github_run_count)
    bamboo_status = fetch_bamboo_status(check_suite.bamboo_ci_ref)
    db_running    = check_suite.running?
    status        = classify(bamboo_finished?(bamboo_status), bamboo_status)

    log_suite_result(check_suite.bamboo_ci_ref, github_run_count, db_running, bamboo_status, status)

    {
      pr_id: check_suite.pull_request.github_pr_id,
      repository: check_suite.pull_request.repository,
      bamboo_ref: check_suite.bamboo_ci_ref,
      status: status,
      check_suite: check_suite
    }
  end

  def log_suite_result(bamboo_ref, github_run_count, db_running, bamboo_status, status)
    db_state     = db_running ? 'running' : 'done'
    bamboo_stage = bamboo_status&.dig('currentStage') || 'N/A'
    msg = "    bamboo=#{bamboo_ref} | gh_runs=#{github_run_count} "
    msg += "| DB: #{db_state} | Bamboo stage: #{bamboo_stage} | #{status}"
    log_and_print msg
  end

  def fetch_bamboo_status(bamboo_ref)
    get_request(URI("https://127.0.0.1/rest/api/latest/result/status/#{bamboo_ref}"))
  rescue StandardError => e
    @logger.error "    Failed fetching Bamboo status for #{bamboo_ref}: #{e.message}"
    nil
  end

  # Returns true when Bamboo considers the build no longer active.
  def bamboo_finished?(status)
    return true if status.nil? || status.empty?

    bamboo_stopped?(status) || bamboo_at_final_stage?(status) || bamboo_progress_done?(status)
  end

  # Bamboo returns a 'message' key with no 'finished' key when a plan was stopped.
  def bamboo_stopped?(status)
    status.key?('message') && !status.key?('finished')
  end

  def bamboo_at_final_stage?(status)
    status['currentStage']&.casecmp('final')&.zero?
  end

  # percentageCompleted >= 2.0 means Bamboo's progress probe considers the build done.
  def bamboo_progress_done?(status)
    status.dig('progress', 'percentageCompleted').to_f >= 2.0
  end

  # GitHub active runs are the source of truth; classify solely based on Bamboo's response.
  def classify(bamboo_done, bamboo_status)
    return :unreachable if bamboo_status.nil? || bamboo_status.empty?

    bamboo_done ? :stale : :ok_running
  end

  def sync(check_suite)
    @logger.info "  Triggering sync for #{check_suite.bamboo_ci_ref}"
    Github::PlanExecution::Finished
      .new({ 'bamboo_ref' => check_suite.bamboo_ci_ref, 'hanged' => true })
      .finished
  rescue StandardError => e
    @logger.error "  Sync failed for #{check_suite.bamboo_ci_ref}: #{e.message}"
  end

  def print_report(results)
    grouped = results.group_by { |r| r[:status] }

    puts "\n#{'=' * 60}\nPR / Bamboo Sync Report\n#{'=' * 60}"
    print_counts(grouped, results.size)
    sync_stale_suites(grouped.fetch(:stale, []))
    report_unreachable_refs(grouped.fetch(:unreachable, []))
    puts '=' * 60
  end

  def print_counts(grouped, total)
    puts "\nRunning (OK)   : #{grouped.fetch(:ok_running, []).size}"
    puts "Unreachable    : #{grouped.fetch(:unreachable, []).size}"
    puts "Stale (syncing): #{grouped.fetch(:stale, []).size}"
    puts "Total checked  : #{total}"
  end

  def sync_stale_suites(stale)
    return if stale.empty?

    puts "\nStale check suites being synchronized:"
    stale.each do |r|
      log_and_print "  => PR ##{r[:pr_id]} (#{r[:repository]}) #{r[:bamboo_ref]}"
      sync(r[:check_suite])
    end
  end

  def report_unreachable_refs(unreachable)
    return if unreachable.empty?

    puts "\nUnreachable Bamboo references (manual review needed):"
    unreachable.each do |r|
      puts "  => PR ##{r[:pr_id]} (#{r[:repository]}) #{r[:bamboo_ref]}"
    end
  end

  def log_and_print(message)
    puts message
    @logger.info message
  end
end

sync = PrBambooSync.new
sync.perform
