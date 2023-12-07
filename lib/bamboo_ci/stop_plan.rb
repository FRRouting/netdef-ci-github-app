#  SPDX-License-Identifier: BSD-2-Clause
#
#  stop_plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class StopPlan
    extend BambooCi::Api

    def self.stop(job_key)
      @logger = Logger.new($stdout)
      delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{job_key}"))
    end

    def self.build(bamboo_ci_ref)
      get_request(URI("https://127.0.0.1/build/admin/stopPlan.action?planResultKey=#{bamboo_ci_ref}"))
    end

    def self.comment(check_suite, new_check_suite)
      url = "https://github.com/#{check_suite.pull_request.repository}/pull/#{check_suite.pull_request.github_pr_id}"
      comment = "GitHub Merge Request #{check_suite.pull_request.github_pr_id} (#{url})\n"
      comment += "for GitHub Repo #{check_suite.pull_request.repository}, " \
                 "branch #{check_suite.merge_branch}\n\n"

      new_url = "https://ci1.netdef.org/browse/#{new_check_suite.bamboo_ci_ref}"
      comment += "This execution was cancelled due to a new run (#{new_url})"

      add_comment_to_ci(check_suite.bamboo_ci_ref, comment)
    end
  end
end
