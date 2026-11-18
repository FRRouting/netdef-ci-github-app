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

      # previous: { last: the suite the new one replaces, stopped: the suites this rerun stopped }
      def self.schedule(queue, payload, check_suite, plan, previous)
        delay(run_at: RETRY_DELAY.seconds.from_now.utc, queue: queue)
          .run(payload, check_suite.id, plan.id, previous[:last]&.id, Array(previous[:stopped]).map(&:id))

        [202, 'GitHub Checks setup rescheduled']
      end

      def self.run(payload, check_suite_id, plan_id, last_check_suite_id, stopped_check_suite_ids)
        check_suite = CheckSuite.find_by(id: check_suite_id)
        plan = Plan.find_by(id: plan_id)

        return [404, 'Check Suite or Plan not found'] if check_suite.nil? or plan.nil?

        new(payload).resume(check_suite, plan, CheckSuite.find_by(id: last_check_suite_id),
                            CheckSuite.where(id: stopped_check_suite_ids).to_a)
      end

      def resume(check_suite, plan, last_check_suite, stopped_check_suites)
        @resume = true
        @github_check = Github::Check.new(check_suite)
        @last_check_suite = last_check_suite
        @stopped_check_suites = stopped_check_suites

        record_full_retry(check_suite) unless AuditRetry.exists?(check_suite: check_suite, retry_type: 'full')
        ci_jobs(check_suite, plan)

        [201, 'Re-run GitHub checks resumed']
      end
    end
  end
end
