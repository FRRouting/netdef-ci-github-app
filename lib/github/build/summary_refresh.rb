#  SPDX-License-Identifier: BSD-2-Clause
#
#  summary_refresh.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../helpers/delayed_job_lookup'

module Github
  module Build
    # Schedules the CiJobStatus job that rebuilds the stage summaries after a job changed status.
    # Only one is kept per execution, on the pull request's numeric queue, so the updates of a pull request
    # are processed in order by the same worker.
    module SummaryRefresh
      def self.schedule(job)
        check_suite = job.check_suite
        queue = queue_for(check_suite)

        pending(check_suite, queue).destroy_all

        CiJobStatus
          .delay(run_at: DELAYED_JOB_TIMER.seconds.from_now.utc, queue: queue)
          .update(check_suite.bamboo_ci_ref, job.id)
      end

      # to_i guards against a database where github_pr_id is a string: String#% formats instead of
      # taking the remainder, so the job would land in a queue no worker consumes.
      def self.queue_for(check_suite)
        check_suite.pull_request.github_pr_id.to_i % 10
      end

      def self.pending(check_suite, queue)
        DelayedJobLookup.pending(queue: queue, method: :update, first_arg: check_suite.bamboo_ci_ref)
      end
    end
  end
end
