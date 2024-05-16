#  SPDX-License-Identifier: BSD-2-Clause
#
#  comment.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'base'

module Github
  module Retry
    class Comment < Base
      def initialize(payload, logger_level: Logger::INFO)
        super(payload)

        create_logger(logger_level)

        @payload = payload

        fetch_stage
        @comment_id = comment_id
      end

      def start
        output = super

        logger(Logger::INFO, "Github::Retry::Comment - response #{output.inspect}")
        if [404, 406, 422].include?(output.first.to_i)
          github_reaction_feedback_down(@comment_id)

          return output
        end

        github_reaction_feedback(@comment_id)

        output
      end

      private

      def fetch_stage
        pull_request = PullRequest.find_by(github_pr_id: pr_id)
        return unless pull_request

        @check_suite = pull_request.check_suites.last
        @stage = @check_suite.stages_failure.min_by(&:id)
      end

      def pr_id
        @payload.dig('issue', 'number')
      end

      def comment_id
        @payload.dig('comment', 'id')
      end
    end
  end
end
