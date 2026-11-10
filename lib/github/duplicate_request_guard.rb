#  SPDX-License-Identifier: BSD-2-Clause
#
#  duplicate_request_guard.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  # Several ci:retry / ci:rerun triggers for the same target can arrive within
  # a few seconds (repeated comments, GitHub "Re-run" firing one event per check
  # run, webhook redeliveries). Each one runs stop + queue in Bamboo, so a late
  # duplicate stops the execution the first one has just started.
  #
  # The claim is a single conditional UPDATE: PostgreSQL re-evaluates the WHERE
  # clause after the row lock is released, so only one concurrent request wins.
  module DuplicateRequestGuard
    WINDOW = 60 # seconds

    def self.claim_retry?(check_suite)
      claim?(CheckSuite, check_suite.id, :retry_requested_at)
    end

    def self.claim_rerun?(pull_request)
      claim?(PullRequest, pull_request.id, :rerun_requested_at)
    end

    def self.claim?(model, id, column)
      now = Time.now.utc

      model
        .unscoped
        .where(id: id)
        .where("#{column} IS NULL OR #{column} < ?", now - WINDOW)
        .update_all(column => now) == 1
    end
  end
end
