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
      new_url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{new_check_suite.bamboo_ci_ref}"
      comment = "This execution was cancelled due to a new commit or `ci:rerun` (#{new_url})"

      add_comment_to_ci(check_suite.bamboo_ci_ref, comment)
    end
  end
end
