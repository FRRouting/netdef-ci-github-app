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

    # Bamboo may not list the jobs of a build that has just started.
    class Unavailable < StandardError; end

    # Like fetch, but raises when Bamboo does not list any job yet, so the GitHub setup can be tried again.
    def self.fetch!(plan_key)
      jobs = fetch(plan_key)
      raise Unavailable, "Bamboo did not return the jobs of #{plan_key}" if jobs.nil? or jobs.empty?

      jobs
    end

    def self.fetch(plan_key)
      @logger = GithubLogger.instance.create('github_running_plan.log', Logger::INFO)

      resp = get_request(URI("https://127.0.0.1/rest/api/latest/result/#{plan_key}?expand=stages.stage.results"))

      return [] if resp.nil? or resp.empty? or resp.dig('stages', 'stage').nil?

      mount_jobs(resp)
    end

    def self.mount_jobs(resp)
      jobs = []
      resp.dig('stages', 'stage').each do |stage|
        Array(stage.dig('results', 'result')).each do |job|
          jobs << { name: job.dig('plan', 'shortName'), job_ref: job['key'], stage: job['stage'] }
        end
      end

      jobs
    end
  end
end
