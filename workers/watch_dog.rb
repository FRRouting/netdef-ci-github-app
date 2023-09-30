#  SPDX-License-Identifier: BSD-2-Clause
#
#  watch_dog.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require_relative '../database_loader'
require_relative '../lib/bamboo_ci/api'
require_relative '../lib/github/check'
require_relative '../lib/helpers/configuration'

class WatchDog
  ONE_HOUR = 1 * 60 * 60

  include BambooCi::Api

  def perform
    @logger = Logger.new('watch_dog.log', 0, 1_024_000)
    check_suites.each do |check_suite|
      @logger.info ">>> CheckSuite: #{check_suite.inspect}"

      fetch_ci_execution(check_suite)

      @logger.info ">>> Status: #{@result['state']}"

      next if @result['status-code'] == 404
      next if @result['state'] == 'Unknown'

      check_stages(check_suite)
      clear_deleted_jobs(check_suite)
    end
  end

  private

  def check_suites
    CheckSuite.where(id: check_suites_fetch_map)
  end

  def check_suites_fetch_map
    CheckSuite
      .joins(:ci_jobs)
      .where(ci_jobs: { status: %w[queued in_progress] }, created_at: [..Time.now - ONE_HOUR])
      .map(&:id)
      .uniq
  end

  def fetch_ci_execution(check_suite)
    @result = get_status(check_suite.bamboo_ci_ref)
  end

  # This method will move all tests that no longer exist in BambooCI to the skipped state,
  # because there are no executions for them.
  def clear_deleted_jobs(check_suite)
    github_check = Github::Check.new(check_suite)

    check_suite.ci_jobs.where(status: %w[queued in_progress]).each do |ci_job|
      ci_job.skipped(github_check)
    end
  end

  def check_stages(check_suite)
    github_check = Github::Check.new(check_suite)
    @result.dig('stages', 'stage').each do |stage|
      stage.dig('results', 'result').each do |result|
        bamboo_ci_ref = result['buildResultKey']

        ci_job = CiJob.find_by(job_ref: bamboo_ci_ref, check_suite_id: check_suite.id)

        @logger.info ">>> CiJob: #{ci_job.inspect} - Finished? #{ci_job.finished?}"
        next if ci_job.finished?

        update_ci_job_status(github_check, ci_job, result['state'])
      end
    end
  end

  def update_ci_job_status(github_check, ci_job, state)
    url = "https://ci1.netdef.org/browse/#{ci_job.job_ref}"
    output = {
      title: ci_job.name,
      summary: "Details at [#{url}](#{url})\nUnfortunately we were unable to access the execution results."
    }

    @logger.info ">>> CiJob: #{ci_job.inspect} updating status"
    case state
    when 'Unknown'
      ci_job.cancelled(github_check, output)
    when 'Failed'
      ci_job.failure(github_check, output)
    when 'Successful'
      ci_job.success(github_check, output)
    else
      puts 'Ignored'
    end
  end
end

watch_dog = WatchDog.new
watch_dog.perform
