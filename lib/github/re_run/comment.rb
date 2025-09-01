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

require_relative 'base'

module Github
  module ReRun
    class Comment < Base
      def initialize(payload, logger_level: Logger::INFO)
        super(payload, logger_level: logger_level)

        @logger_manager << GithubLogger.instance.create('github_rerun_comment.log', logger_level)
        @logger_manager << Logger.new($stdout)
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?
        return [404, 'Action not found'] unless action?

        logger(Logger::DEBUG, ">>> Github::ReRun::Comment - sha256: #{sha256.inspect}, payload: #{@payload.inspect}")

        fetch_pull_request

        confirm_and_start
      end

      private

      def confirm_and_start
        return [404, 'Pull Request not found'] if @pull_request.nil?
        return [404, 'Can not rerun a new PullRequest'] if @pull_request.check_suites.empty?

        github_reaction_feedback(comment_id)

        status = nil

        @pull_request.plans.each do |plan|
          status = run_by_plan(plan)
        end

        status
      end

      def run_by_plan(plan)
        check_suite = sha256_or_comment?
        logger(Logger::DEBUG, ">>> Check suite: #{check_suite.inspect}")

        return [404, 'Failed to create a check suite'] if check_suite.nil?

        check_suite.update(plan: plan)

        stop_previous_execution(plan)

        start_new_execution(check_suite, plan)

        ci_jobs(check_suite, plan)

        [201, 'Starting re-run (comment)']
      end

      def fetch_pull_request
        @pull_request = PullRequest.find_by(github_pr_id: pr_id)
      end

      def sha256_or_comment?
        fetch_old_check_suite

        @old_check_suite.nil? ? comment_flow : sha256_flow
      end

      def comment_flow
        commit = fetch_last_commit_or_sha256
        github_check = fetch_github_check
        pull_request_info = github_check.pull_request_info(pr_id, repo)

        fetch_old_check_suite(commit[:sha])
        check_suite = create_check_suite_by_commit(commit, @pull_request, pull_request_info)
        logger(Logger::INFO, "CheckSuite errors: #{check_suite.inspect}")
        return nil unless check_suite.persisted?

        @github_check = Github::Check.new(check_suite)

        check_suite
      end

      # Fetches the GitHub check associated with the pull request.
      #
      # This method finds the pull request by its GitHub PR ID and then retrieves
      # the last check suite associated with that pull request. It then initializes
      # a new `Github::Check` object with the last check suite.
      #
      # @return [Github::Check] the GitHub check associated with the pull request.
      #
      # @raise [ActiveRecord::RecordNotFound] if the pull request is not found.
      def fetch_github_check
        pull_request = PullRequest.find_by(github_pr_id: pr_id)
        Github::Check.new(pull_request.check_suites.last)
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

        github_check = Github::Check.new(@pull_request.check_suites.last)

        github_check.comment_reaction_thumb_up(repo, comment_id)
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
          pull_request: @pull_request,
          author: @old_check_suite.author,
          commit_sha_ref: @old_check_suite.commit_sha_ref,
          work_branch: @old_check_suite.work_branch,
          base_sha_ref: @old_check_suite.base_sha_ref,
          merge_branch: @old_check_suite.merge_branch,
          re_run: true
        )
      end

      def sha256
        return nil unless action.downcase.match? 'ci:rerun #'

        action.downcase.split('#').last
      end

      def action?
        action.to_s.downcase.match? 'ci:rerun' and @payload['action'] == 'created'
      end
    end
  end
end
