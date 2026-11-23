#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class Retry
    extend BambooCi::Api

    class RestartFailed < StandardError; end

    def self.restart(plan_key)
      @logger = Logger.new($stdout)
      PrometheusMetrics.track_bamboo('retry_plan') do
        put_request(URI(bamboo_url("/rest/api/latest/queue/#{plan_key}?executeAllStages=true")))
      end
    end

    # Like restart, but raises unless Bamboo accepted the restart (no answer or an HTTP error).
    def self.restart!(plan_key)
      response = restart(plan_key)
      return response if response.is_a?(Net::HTTPSuccess)

      raise RestartFailed, "Bamboo did not restart #{plan_key}: HTTP #{response&.code || 'no response'}"
    end

    def self.rerun(plan_key)
      @logger = Logger.new($stdout)
      url = bamboo_url("/rest/api/latest/queue/#{plan_key}?executeAllStages=true&orphanRemoval=true")
      resp = PrometheusMetrics.track_bamboo('rerun_plan') do
        put_request(URI(url))
      end

      @logger.info "URL: #{url} -> (#{resp&.code}) - #{resp&.body}"

      resp&.body
    end
  end
end
