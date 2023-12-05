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

    def self.build(ci_key)
      get_request(URI("https://127.0.0.1/build/admin/stopPlan.action?planResultKey=#{ci_key}"))
    end
  end
end
