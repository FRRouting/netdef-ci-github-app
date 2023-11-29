#  SPDX-License-Identifier: BSD-2-Clause
#
#  result.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative 'api'

module BambooCi
  class Result
    extend BambooCi::Api

    def self.fetch(job_key, expand: 'testResults.failedTests.testResult.errors')
      uri = URI("https://127.0.0.1/rest/api/latest/result/#{job_key}?expand=#{expand}")
      get_request(uri)
    end
  end
end
