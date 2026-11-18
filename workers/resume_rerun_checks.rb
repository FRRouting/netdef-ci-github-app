#  SPDX-License-Identifier: BSD-2-Clause
#
#  resume_rerun_checks.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

# Delayed Job entry point for the GitHub side of a rerun whose Bamboo plan has already started.
# The logic lives in Github::ReRun::ChecksResume, which never starts or stops a new build, so it is safe to retry.
class ResumeRerunChecks
  def self.run(payload, check_suite_id, plan_id)
    check_suite = CheckSuite.find_by(id: check_suite_id)
    plan = Plan.find_by(id: plan_id)

    return [404, 'Check Suite or Plan not found'] if check_suite.nil? or plan.nil?

    Github::ReRun::ChecksResume.new(payload).resume(check_suite, plan)
  end
end
