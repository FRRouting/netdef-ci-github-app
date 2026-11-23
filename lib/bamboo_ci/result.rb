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

    ACTIVE_STATES = %w[Queued Pending InProgress].freeze

    def self.fetch(job_key, expand: 'testResults.failedTests.testResult.errors')
      uri = URI(bamboo_url("/rest/api/latest/result/#{job_key}?expand=#{expand}"))
      get_request(uri)
    end

    # Without a clear answer from Bamboo the build is taken as running: stopping a finished build
    # costs a misleading comment, leaving a running one costs a whole CI run.
    def self.active?(bamboo_ci_ref)
      result = fetch(bamboo_ci_ref, expand: '')
      state = result['lifeCycleState'] if result.is_a?(Hash)

      state.nil? or ACTIVE_STATES.include?(state)
    end
  end
end
