#  SPDX-License-Identifier: BSD-2-Clause
#
#  checks_resume.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'base'

module Github
  module ReRun
    # GitHub side of a rerun whose Bamboo plan has already started. It never stops or starts a build,
    # so Delayed Job can retry it safely.
    class ChecksResume < Base
      RETRY_DELAY = 10 # seconds

      def self.schedule(queue, payload, check_suite, plan)
        ResumeRerunChecks
          .delay(run_at: RETRY_DELAY.seconds.from_now.utc, queue: queue)
          .run(payload, check_suite.id, plan.id)

        [202, 'GitHub Checks setup rescheduled']
      end

      def resume(check_suite, plan)
        @resume = true
        @github_check = Github::Check.new(check_suite)

        return give_way(check_suite) if check_suite.superseded?

        create_github_checks(check_suite, plan)

        [201, 'Re-run GitHub checks resumed']
      end

      private

      # A newer rerun replaced this one while its checks were pending. That rerun only stops suites with a
      # job in progress, so this build is stopped here instead. Its open jobs and stages are closed in the
      # database only: a new 'cancelled' check run would carry the same name as the newer rerun's checks on
      # the same commit and hide them.
      def give_way(check_suite)
        unless BambooCi::StopPlan.stop_execution(check_suite.bamboo_ci_ref)
          logger(Logger::ERROR, ">>> Bamboo refused to stop superseded #{check_suite.bamboo_ci_ref}")
          return [200, 'Superseded by a newer execution']
        end

        cancelled = CiJob.statuses[:cancelled]
        check_suite.ci_jobs.where(status: Github::Build::OpenChecks::STATUSES).update_all(status: cancelled)
        check_suite.stages.where(status: Github::Build::OpenChecks::STATUSES).update_all(status: cancelled)

        [200, 'Superseded by a newer execution']
      end
    end
  end
end
