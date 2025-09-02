#   SPDX-License-Identifier: BSD-2-Clause
#
#   plan_run.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

module Github
  module Build
    class PlanRun
      TIMER = 5 # seconds
      def initialize(pull_request, payload)
        @pull_request = pull_request
        @payload = payload
      end

      def build
        return [422, 'No Plans associated with this Pull Request'] if @pull_request.plans.empty?

        @pull_request.plans.each do |plan|
          CreateExecutionByPlan
            .delay(run_at: TIMER.seconds.from_now.utc, queue: 'create_execution_by_plan')
            .create(@pull_request.id, @payload, plan)
        end

        [200, 'Scheduled Plan Runs']
      end
    end
  end
end
