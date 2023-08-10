# frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class RunningPlan
    extend BambooCi::Api

    def self.fetch(plan_key)
      @logger = Logger.new($stdout)
      resp = get_request(URI("https://127.0.0.1/rest/api/latest/result/#{plan_key}?expand=stages.stage.results"))

      return [] if resp.nil? or resp.empty?

      jobs = []
      resp.dig('stages', 'stage').each do |stage|
        stage.dig('results', 'result').each do |job|
          jobs << { name: job.dig('plan', 'shortName'), job_ref: job['key'] }
        end
      end

      jobs
    end
  end
end
