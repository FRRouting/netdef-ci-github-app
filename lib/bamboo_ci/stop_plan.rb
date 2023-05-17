# frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class StopPlan
    extend BambooCi::Api

    def self.stop(job_key)
      @logger = Logger.new($stdout)
      delete_request(URI("https://127.0.0.1/rest/api/latest/queue/#{job_key}"))
    end
  end
end
