#  SPDX-License-Identifier: BSD-2-Clause
#
#  running_plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'
require_relative '../helpers/github_logger'

module BambooCi
  class RunningPlan
    extend BambooCi::Api

    def self.fetch(plan_key)
      @logger = GithubLogger.instance.create('github_running_plan.log', Logger::INFO)

      resp = get_request(URI("https://127.0.0.1/rest/api/latest/result/#{plan_key}?expand=stages.stage.results"))

      return [] if resp.nil? or resp.empty? or resp.dig('stages', 'stage').nil?

      mount_jobs(resp)
    end

    def self.mount_jobs(resp)
      jobs = []
      resp.dig('stages', 'stage').each do |stage|
        stage.dig('results', 'result').each do |job|
          jobs << { name: job.dig('plan', 'shortName'), job_ref: job['key'], stage: job['stage'] }
        end
      end

      jobs
    end
  end
end
