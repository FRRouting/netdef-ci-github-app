# frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class Retry
    extend BambooCi::Api

    def self.restart(plan_key)
      @logger = Logger.new($stdout)
      put_request(URI("https://127.0.0.1/rest/api/latest/queue/#{plan_key}?executeAllStages=true"))
    end
  end
end
