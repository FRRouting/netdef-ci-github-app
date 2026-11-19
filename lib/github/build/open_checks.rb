#  SPDX-License-Identifier: BSD-2-Clause
#
#  open_checks.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    # Cancels the queued / running jobs and stages of a stopped execution. Shared by the new-commit flow
    # (ChecksSetup) and the rerun flow, so both agree on what counts as open. Finished checks are kept.
    module OpenChecks
      STATUSES = %w[queued in_progress].freeze

      # The GitHub client is built for the stopped suite: Stage#cancelled creates a new check run on the
      # client's commit, and the suite that replaced this one may be on another commit.
      def self.cancel(check_suite)
        github = Github::Check.new(check_suite)

        check_suite.ci_jobs.where(status: STATUSES).each { |job| job.cancelled(github) }

        # An open stage would be finished later by the watchdog, which creates a new check run on the
        # same commit and hides the checks of the new execution.
        check_suite.stages.where(status: STATUSES).each { |stage| stage.cancelled(github) }
      end

      # A newer execution replaced this one while its GitHub setup was pending. The newer one only stops
      # suites with a job in progress, so this build is stopped here. Its open jobs and stages are closed in
      # the database only: a new 'cancelled' check run would carry the same name as the newer execution's
      # checks on the same commit and hide them. Returns false when Bamboo refused to stop the build.
      def self.close_superseded(check_suite)
        return false unless BambooCi::StopPlan.stop_execution(check_suite.bamboo_ci_ref)

        cancelled = CiJob.statuses[:cancelled]
        check_suite.ci_jobs.where(status: STATUSES).update_all(status: cancelled)
        check_suite.stages.where(status: STATUSES).update_all(status: cancelled)

        true
      end
    end
  end
end
