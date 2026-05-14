#  SPDX-License-Identifier: BSD-2-Clause
#
#  stuck_jobs_watchdog.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'

class StuckJobsWatchdog
  def perform
    @logger = GithubLogger.instance.create('stuck_jobs_watchdog.log', Logger::INFO)
    @logger.info('>>> Running StuckJobsWatchdog')

    jobs = stuck_jobs

    @logger.info(">>> Stuck jobs found: #{jobs.size}")

    finalize(jobs)

    @logger.info('>>> StuckJobsWatchdog finished')
  end

  private

  def stuck_jobs
    CiJob
      .in_progress
      .where(updated_at: 24.hours.ago.utc..2.hours.ago.utc)
  end

  def finalize(jobs)
    jobs.each do |job|
      @logger.info(">>> Finalizing stuck job id=#{job.id} name=#{job.name} updated_at=#{job.updated_at}")

      github = Github::Check.new(job.check_suite)
      job.failure(github, agent: 'StuckJobsWatchdog')
      Github::Build::Summary.new(job).build_summary
    end
  end
end

watchdog = StuckJobsWatchdog.new
watchdog.perform
