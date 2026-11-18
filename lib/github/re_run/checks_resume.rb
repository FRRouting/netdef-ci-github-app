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
        delay(run_at: RETRY_DELAY.seconds.from_now.utc, queue: queue).run(payload, check_suite.id, plan.id)

        [202, 'GitHub Checks setup rescheduled']
      end

      def self.run(payload, check_suite_id, plan_id)
        check_suite = CheckSuite.find_by(id: check_suite_id)
        plan = Plan.find_by(id: plan_id)

        return [404, 'Check Suite or Plan not found'] if check_suite.nil? or plan.nil?

        new(payload).resume(check_suite, plan)
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
      # job in progress, so this build and whatever checks it already has are stopped here instead.
      def give_way(check_suite)
        BambooCi::StopPlan.stop_execution(check_suite.bamboo_ci_ref)
        Github::Build::OpenChecks.cancel(check_suite, @github_check)

        [200, 'Superseded by a newer execution']
      end
    end
  end
end
