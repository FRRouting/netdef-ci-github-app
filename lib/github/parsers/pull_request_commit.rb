# frozen_string_literal: true

module Github
  module Parsers
    class PullRequestCommit
      def initialize(repo, pr_id)
        @repo = repo
        @pr_id = pr_id

        @github_check = Github::Check.new(nil)
      end

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
