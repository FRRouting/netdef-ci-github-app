#  SPDX-License-Identifier: BSD-2-Clause
#
#  re_run.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/retry'
require_relative '../bamboo_ci/stop_plan'
require_relative 'parsers/pull_request_commit'

require_relative 'check'

module Github
  class ReRun
    def initialize(payload, logger_level: Logger::INFO)
      @logger_manager = []
      @logger_level = logger_level

      logger_class = Logger.new('github_rerun.log', 0, 1_024_000)
      logger_class.level = logger_level

      logger_app = Logger.new('github_app.log', 1, 1_024_000)
      logger_app.level = logger_level

      @logger_manager << logger_class
      @logger_manager << logger_app

      @payload = payload
    end

    def start
      return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?
      return [404, 'Action not found'] unless action?

      logger(Logger::DEBUG, ">>> Github::ReRun - sha256: #{sha256.inspect}, payload: #{@payload.inspect}")

      check_suite = sha256_or_comment?

      logger(Logger::DEBUG, ">>> Check suite: #{check_suite.inspect}")

      return [404, 'Failed to create a check suite'] if check_suite.nil?

      github_reaction_feedback(comment_id)

      stop_previous_execution

      bamboo_plan = start_new_execution(check_suite)

      ci_jobs(check_suite, bamboo_plan)

      [201, 'Starting re-run']
    end

    private

    def sha256_or_comment?
      fetch_old_check_suite

      @old_check_suite.nil? ? comment_flow : sha256_flow
    end

    def comment_flow
      commit = fetch_last_commit_or_sha256
      github_check = Github::Check.new(nil)
      pull_request_info = github_check.pull_request_info(pr_id, repo)
      pull_request = fetch_or_create_pr(pull_request_info)

      fetch_old_check_suite(commit[:sha])
      check_suite = create_check_suite_by_commit(commit, pull_request, pull_request_info)
      logger(Logger::INFO, "CheckSuite errors: #{check_suite.inspect}")
      return nil unless check_suite.persisted?

      @github_check = Github::Check.new(check_suite)

      check_suite
    end

    def create_check_suite_by_commit(commit, pull_request, pull_request_info)
      CheckSuite.create(
        pull_request: pull_request,
        author: @payload.dig('comment', 'user', 'login'),
        commit_sha_ref: commit[:sha],
        work_branch: pull_request_info.dig(:head, :ref),
        base_sha_ref: pull_request_info.dig(:base, :sha),
        merge_branch: pull_request_info.dig(:base, :ref),
        re_run: true
      )
    end

    def fetch_or_create_pr(pull_request_info)
      last_check_suite = CheckSuite
                         .joins(:pull_request)
                         .where(pull_request: { github_pr_id: pr_id, repository: repo })
                         .last

      return last_check_suite.pull_request unless last_check_suite.nil?

      pull_request = create_pull_request(pull_request_info)

      logger(Logger::DEBUG, ">>> Created a new pull request: #{pull_request}")
      logger(Logger::ERROR, "Error: #{pull_request.errors.inspect}") unless pull_request.persisted?

      pull_request
    end

    def create_pull_request(pull_request_info)
      PullRequest.create(
        author: @payload.dig('issue', 'user', 'login'),
        github_pr_id: pr_id,
        branch_name: pull_request_info.dig(:head, :ref),
        repository: repo,
        plan: fetch_plan
      )
    end

    def sha256_flow
      @github_check = Github::Check.new(@old_check_suite)
      create_new_check_suite
    end

    # The behaviour will be the following: It will fetch the last commit if it has
    # received a comment and only fetch a commit if the command starts with ci:rerrun #<sha256>.
    # If there is any other character before the # it will be considered a comment.
    def fetch_last_commit_or_sha256
      pull_request_commit = Github::Parsers::PullRequestCommit.new(repo, pr_id)
      commit = pull_request_commit.find_by_sha(sha256)

      return commit if commit and action.match(/ci:rerun\s+#/i)

      fetch_last_commit
    end

    def fetch_last_commit
      Github::Parsers::PullRequestCommit.new(repo, pr_id).last_commit_in_pr
    end

    def github_reaction_feedback(comment_id)
      return if comment_id.nil?

      @github_check.comment_reaction_thumb_up(repo, comment_id)
    end

    def fetch_old_check_suite(sha = sha256)
      return if sha.nil?

      logger(Logger::DEBUG, ">>> fetch_old_check_suite SHA: #{sha}")

      @old_check_suite =
        CheckSuite
        .joins(:pull_request)
        .where('commit_sha_ref ILIKE ? AND pull_requests.repository = ?', "#{sha}%", repo)
        .last
    end

    def create_new_check_suite
      CheckSuite.create(
        pull_request: @old_check_suite.pull_request,
        author: @old_check_suite.author,
        commit_sha_ref: @old_check_suite.commit_sha_ref,
        work_branch: @old_check_suite.work_branch,
        base_sha_ref: @old_check_suite.base_sha_ref,
        merge_branch: @old_check_suite.merge_branch,
        re_run: true
      )
    end

    def action
      @payload.dig('comment', 'body')
    end

    def pr_id
      @payload.dig('issue', 'number')
    end

    def repo
      @payload.dig('repository', 'full_name')
    end

    def comment_id
      @payload.dig('comment', 'id')
    end

    def sha256
      return nil unless action.downcase.match? 'ci:rerun #'

      action.downcase.split('#').last
    end

    def action?
      return false if action.nil?

      action.downcase.match? 'ci:rerun' and @payload['action'] == 'created'
    end

    def start_new_execution(check_suite)
      bamboo_plan_run = BambooCi::PlanRun.new(check_suite, logger_level: @logger_level)
      bamboo_plan_run.ci_variables = ci_vars
      bamboo_plan_run.start_plan
      bamboo_plan_run
    end

    def ci_vars
      ci_vars = []
      ci_vars << { value: @github_check.signature, name: 'signature_secret' }

      ci_vars
    end

    def fetch_run_ci_by_pr
      CheckSuite
        .joins(:pull_request)
        .joins(:ci_jobs)
        .where(pull_request: { github_pr_id: pr_id, repository: repo }, ci_jobs: { status: 1 })
        .uniq
    end

    def stop_previous_execution
      return if fetch_run_ci_by_pr.empty?

      logger(Logger::INFO, 'Stopping previous execution')
      logger(Logger::INFO, fetch_run_ci_by_pr.inspect)

      fetch_run_ci_by_pr.each do |check_suite|
        check_suite.ci_jobs.each do |ci_job|
          BambooCi::StopPlan.stop(ci_job.job_ref)

          logger(Logger::WARN, "Cancelling Job #{ci_job.inspect}")
          ci_job.cancelled(@github_check)
        end
      end
    end

    def ci_jobs(check_suite, bamboo_plan)
      check_suite.update(bamboo_ci_ref: bamboo_plan.bamboo_reference)

      create_ci_jobs(bamboo_plan, check_suite)
    end

    def create_ci_jobs(bamboo_plan, check_suite)
      jobs = BambooCi::RunningPlan.fetch(bamboo_plan.bamboo_reference)

      jobs.each do |job|
        ci_job = CiJob.create(
          check_suite: check_suite,
          name: job[:name],
          job_ref: job[:job_ref]
        )

        logger(Logger::DEBUG, ">>> CI Job: #{ci_job.inspect}")
        next unless ci_job.persisted?

        ci_job.enqueue(@github_check)

        next unless ci_job.checkout_code?

        url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
        ci_job.in_progress(@github_check, { title: ci_job.name, summary: "Details at [#{url}](#{url})" })
      end
    end

    def fetch_plan
      plan = Plan.find_by_github_repo_name(@payload.dig('repository', 'full_name'))

      return plan.bamboo_ci_plan_name unless plan.nil?

      # Default plan
      'TESTING-FRRCRAS'
    end

    def logger(severity, message)
      @logger_manager.each do |logger_object|
        logger_object.add(severity, message)
      end
    end
  end
end
