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
      TIMER = 1 # seconds

      def initialize(payload, logger_level: Logger::INFO)
        super(payload, logger_level: logger_level)

        @logger_manager << GithubLogger.instance.create('github_rerun_comment.log', logger_level)
        @logger_manager << Logger.new($stdout)
      end

      def start
        return [422, 'Payload can not be blank'] if @payload.nil? or @payload.empty?
        return [404, 'Action not found'] unless action?

        fetch_pull_request

        confirm_and_start
      end

      private

      def confirm_and_start
        return [404, 'Pull Request not found'] if @pull_request.nil?
        return [404, 'Can not rerun a new PullRequest'] if @pull_request.check_suites.empty?

        github_reaction_feedback(comment_id)

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

        github_check = Github::Check.new(@pull_request.check_suites.last)

        github_check.comment_reaction_thumb_up(repo, comment_id)
      end

      def fetch_pull_request
        @pull_request = PullRequest.find_by(github_pr_id: pr_id)
      end

      def action?
        action.to_s.downcase.match? 'ci:rerun' and @payload['action'] == 'created'
      end
    end
  end
end
