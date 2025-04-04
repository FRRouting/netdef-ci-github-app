#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request_commit.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Parsers
    # Class responsible for parsing pull request commits.
    class PullRequestCommit
      # Initializes a new PullRequestCommit parser.
      #
      # @param repo [String] the repository name.
      # @param pr_id [Integer] the pull request ID.
      def initialize(repo, pr_id)
        @repo = repo
        @pr_id = pr_id

        pull_request = PullRequest.find_by(github_pr_id: pr_id)

        @github_check = Github::Check.new(pull_request.check_suites.last)
      end

      # Finds a commit by its SHA.
      #
      # @param sha256 [String] the SHA256 hash of the commit.
      # @return [Hash, nil] the commit data if found, otherwise nil.
      def find_by_sha(sha256)
        return nil if sha256.nil?

        page = 1

        loop do
          output = @github_check.fetch_pull_request_commits(@pr_id, @repo, page)

          break if output.empty?

          found = output.find { |entry| entry[:sha][0..7].include? sha256 }
          return found unless found.nil? or found.empty?

          page += 1
        end

        nil
      end

      # Retrieves the last commit in the pull request.
      #
      # @return [Hash, nil] the last commit data if found, otherwise nil.
      def last_commit_in_pr
        page = 1
        last_commit = nil

        loop do
          output = @github_check.fetch_pull_request_commits(@pr_id, @repo, page)

          break if output.last.nil?

          last_commit = output.last
          page += 1
        end

        last_commit
      end
    end
  end
end
