#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job_status.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

class TimeoutExecution
  class << self
    def timeout(check_suite_id)
      @logger = GithubLogger.instance.create('timeout_execution_worker.log', Logger::INFO)
      check_suite = CheckSuite.find(check_suite_id)

      @logger.info("Timeout execution for check_suite_id: #{check_suite_id} -> finished? #{check_suite.finished?}")

      return if check_suite.finished?

      return if check_suite.last_job_updated_at_timer > 2.hour.ago.utc

      @logger.info("Calling Github::PlanExecution::Finished.new(#{check_suite.bamboo_ci_ref}).finished")

      resp =
        Github::PlanExecution::Finished
        .new({ 'bamboo_ref' => check_suite.bamboo_ci_ref, hanged: true })
        .finished

      rescheduling(resp, check_suite_id)
    end

    def rescheduling(resp, check_suite_id)
      return if resp == [200, 'Finished']

      @logger.info("Rescheduling check_suite_id: #{check_suite_id}")

      Delayed::Job.where('handler LIKE ?', "%TimeoutExecution%args%-%#{check_suite_id}%")&.delete_all

      TimeoutExecution
        .delay(run_at: 2.hours.from_now.utc, queue: 'timeout_execution')
        .timeout(check_suite_id)
    end
  end
end
