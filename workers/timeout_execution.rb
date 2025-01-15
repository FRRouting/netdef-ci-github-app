#  SPDX-License-Identifier: BSD-2-Clause
#
#  timeout_execution.rb
#  Part of NetDEF CI System
#
#  This class handles the timeout execution logic for a given CheckSuite.
#  It checks if the CheckSuite has finished or if it needs to be rescheduled
#  or handled by the watchdog process.
#
#  Methods:
#  - timeout(check_suite_id): Main method to handle the timeout logic for a CheckSuite.
#  - watchdog(check_suite): Handles the CheckSuite if it is considered hanged.
#  - rescheduling(check_suite_id): Reschedules the timeout execution for a CheckSuite.
#
#  Example usage:
#    - TimeoutExecution.timeout(check_suite_id)
#    - TimeoutExecution.delay(...).timeout(check_suite_id)
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

class TimeoutExecution
  class << self
    ##
    # Handles the timeout logic for a given CheckSuite.
    # Logs the timeout execution and checks if the CheckSuite has finished.
    # If the CheckSuite has not finished and the last job update was more than 2 hours ago,
    # it calls the watchdog method. Otherwise, it reschedules the timeout execution.
    #
    # @param [Integer] check_suite_id The ID of the CheckSuite to handle.
    # @return [Boolean] Returns false if the CheckSuite has finished or if it is rescheduled.
    def timeout(check_suite_id)
      @logger = GithubLogger.instance.create('timeout_execution_worker.log', Logger::INFO)
      check_suite = CheckSuite.find(check_suite_id)

      @logger.info("Timeout execution for check_suite_id: #{check_suite_id} -> finished? #{check_suite.finished?}")

      return false if check_suite.finished?
      return watchdog(check_suite) if check_suite.last_job_updated_at_timer < 2.hour.ago.utc

      rescheduling(check_suite_id)
    end

    ##
    # Handles the CheckSuite if it is considered hanged.
    # Calls the finished method of Github::PlanExecution::Finished with the hanged flag set to true.
    #
    # @param [CheckSuite] check_suite The CheckSuite to handle.
    def watchdog(check_suite)
      Github::PlanExecution::Finished
        .new({ 'bamboo_ref' => check_suite.bamboo_ci_ref, hanged: true })
        .finished

      true
    end

    ##
    # Reschedules the timeout execution for a given CheckSuite.
    # Logs the rescheduling and deletes any existing delayed jobs for the CheckSuite.
    # Schedules a new timeout execution to run 30 minutes from now.
    #
    # @param [Integer] check_suite_id The ID of the CheckSuite to reschedule.
    def rescheduling(check_suite_id)
      @logger.info("Rescheduling check_suite_id: #{check_suite_id}")

      TimeoutExecution
        .delay(run_at: 30.minute.from_now.utc, queue: 'timeout_execution')
        .timeout(check_suite_id)

      false
    end
  end
end
