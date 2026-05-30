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

    def self.restart(plan_key)
      @logger = Logger.new($stdout)
      PrometheusMetrics.track_bamboo('retry_plan') do
        put_request(URI("https://127.0.0.1/rest/api/latest/queue/#{plan_key}?executeAllStages=true"))
      end
    end

    def self.rerun(plan_key)
      @logger = Logger.new($stdout)
      url = "https://127.0.0.1/rest/api/latest/queue/#{plan_key}?executeAllStages=true&orphanRemoval=true"
      resp = PrometheusMetrics.track_bamboo('rerun_plan') do
        put_request(URI(url))
      end

      @logger.info "URL: #{url} -> (#{resp&.code}) - #{resp&.body}"

      resp&.body
    end
  end
end
