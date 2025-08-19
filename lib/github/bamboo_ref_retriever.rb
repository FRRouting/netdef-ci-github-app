# frozen_string_literal: true

#   SPDX-License-Identifier: BSD-2-Clause
#
#   bamboo_ref_retriever.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

module Github
  class BambooRefRetriever
    def initialize(job, check_suite)
      @check_suite = check_suite
      @job = job
    end

    def fetch
      bamboo_ref = nil
      @check_suite.bamboo_refs.each do |ref|
        jobs = BambooCi::RunningPlan.fetch(ref.bamboo_key)
        info = jobs.find { |job| job[:name] == @job.name }

        if info.present?
          bamboo_ref = info
          bamboo_ref[:bamboo_ci_ref] = ref.bamboo_key
          break
        end
      end

      bamboo_ref
    end
  end
end

