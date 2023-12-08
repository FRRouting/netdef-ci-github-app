#  SPDX-License-Identifier: BSD-2-Clause
#
#  unavailable_jobs.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../check'
require_relative '../../bamboo_ci/running_plan'

module Github
  module Build
    class UnavailableJobs
      def initialize(check_suite)
        return if check_suite.nil?

        @check_suite = check_suite
        @github = Github::Check.new(@check_suite)
        @logger = Logger.new('github_unavailable_jobs.log', 1, 1_024_000)
      end

      def update(new_check_suite: nil)
        return if @check_suite.nil?

        @logger.warn '>>> Check Unavailable Jobs'

        running_jobs =
          BambooCi::RunningPlan.fetch(@check_suite.bamboo_ci_ref).map { |entry| entry[:job_ref] }

        @check_suite.ci_jobs.skip_stages.where.not(job_ref: running_jobs).each do |unavailable_job|
          unavailable_job.skipped(@github, output(unavailable_job))
          unavailable_job.update(check_suite: new_check_suite) unless new_check_suite.nil?
        end
      end

      private

      def output(unavailable_job)
        {
          title: unavailable_job.name,
          summary: 'This check has been removed from the CI execution plan and in your ' \
                   'next commit or rebase it will not be executed and will not appear in the Check Run list.'
        }
      end
    end
  end
end
