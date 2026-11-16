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
require_relative 'running_plan'

module BambooCi
  class StopPlan
    extend BambooCi::Api

    def self.stop(job_key)
      @logger = Logger.new($stdout)
      PrometheusMetrics.track_bamboo('stop_job') do
        delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{job_key}"))
      end
    end

    def self.build(bamboo_ci_ref)
      PrometheusMetrics.track_bamboo('stop_plan') do
        next stop_by_rest(bamboo_ci_ref) if BambooCi::ServiceAccount.instance.configured?

        get_request(URI("https://127.0.0.1/build/admin/stopPlan.action?planResultKey=#{bamboo_ci_ref}"))
      end
    end

    # A service account token only authenticates REST endpoints, so stopPlan.action is not an option.
    # The queue DELETE of the execution only stops it while it waits in the queue, so it is also sent to each job.
    def self.stop_by_rest(bamboo_ci_ref)
      return nil if bamboo_ci_ref.nil?

      response = delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{bamboo_ci_ref}"))

      BambooCi::RunningPlan.fetch(bamboo_ci_ref).filter_map { |job| job[:job_ref] }.each do |job_ref|
        delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{job_ref}"))
      end

      response
    end

    def self.comment(check_suite, new_check_suite)
      new_url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{new_check_suite.bamboo_ci_ref}"
      comment = "This execution was cancelled due to a new commit or `ci:rerun` (#{new_url})"

      add_comment_to_ci(check_suite.bamboo_ci_ref, comment)
    end
  end
end
