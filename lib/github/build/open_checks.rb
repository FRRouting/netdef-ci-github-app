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

      def self.cancel(check_suite, github)
        check_suite.ci_jobs.where(status: STATUSES).each { |job| job.cancelled(github) }

        # An open stage would be finished later by the watchdog, which creates a new check run on the
        # same commit and hides the checks of the new execution.
        check_suite.stages.where(status: STATUSES).each { |stage| stage.cancelled(github) }
      end
    end
  end
end
