#  SPDX-License-Identifier: BSD-2-Clause
#
#  failure_notice.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module ReRun
    # The ci:rerun comment gets its thumbs-up as soon as the request is accepted, before the worker runs. When the
    # worker then fails, this is the only signal the user gets that nothing was started.
    class FailureNotice
      def self.notify(pull_request, payload, plan_name, reason)
        new(pull_request, payload).notify(plan_name, reason)
      end

      def initialize(pull_request, payload)
        @pull_request = pull_request
        @payload = payload
        @logger = GithubLogger.instance.create('github_rerun_comment.log', Logger::INFO)
      end

      def notify(plan_name, reason)
        return if @pull_request.nil?

        github_check = Github::Check.new(@pull_request.check_suites.last)

        github_check.comment_reaction_thumb_down(repository, comment_id) unless comment_id.nil?
        github_check.add_comment(@pull_request.github_pr_id, message(plan_name, reason), repository)
      rescue StandardError => e
        # The notice is best effort: it must never turn a failed rerun into a failing notification job.
        @logger.error("[#{self.class}] Failed to notify PR #{@pull_request&.github_pr_id}: #{e.class}: #{e.message}")
      end

      private

      def message(plan_name, reason)
        "The `ci:rerun` request could not start the CI for plan `#{plan_name}` (#{reason}). " \
          'Please comment `ci:rerun` again; if it keeps failing, contact the CI maintainers.'
      end

      def repository
        @pull_request.repository
      end

      def comment_id
        @payload&.dig('comment', 'id')
      end
    end
  end
end
