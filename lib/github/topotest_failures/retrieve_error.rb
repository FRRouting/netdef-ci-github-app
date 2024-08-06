#  SPDX-License-Identifier: BSD-2-Clause
#
#  retrieve_error.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module TopotestFailures
    class RetrieveError
      attr_reader :failures

      def initialize(job)
        @job = job
        @failures = []
      end

      def retrieve
        fetch_failures(BambooCi::Result.fetch(@job.job_ref))

        @failures
      end

      def fetch_failures(output)
        output.dig('testResults', 'failedTests', 'testResult')&.each do |test_result|
          @failures << {
            'suite' => test_result['className'],
            'case' => test_result['methodName'],
            'message' => test_result.dig('errors', 'error').map { |error| error['message'] }.join("\n"),
            'execution_time' => test_result['durationInSeconds']
          }
        end
      end
    end
  end
end
