#  SPDX-License-Identifier: BSD-2-Clause
#
#  final_sync.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require_relative 'base'
class SingleSync < Base
  def perform(bamboo_ci)
    puts bamboo_ci
    check_suite = CheckSuite.find_by(bamboo_ci_ref: bamboo_ci)

    puts check_suite.inspect

    if check_suite.nil?
      puts 'Please inform the CI that you would like to sync like the example: TESTING-GITHUBCHECKBETA-82'

      return
    end

    fetch_ci_execution(check_suite)

    stages(check_suite)
  end

  private

  def stages(check_suite)
    github_check = Github::Check.new(check_suite)

    check_stages do |result|
      bamboo_ci_ref = result['buildResultKey']

      ci_job = CiJob.find_by(job_ref: bamboo_ci_ref, check_suite_id: check_suite.id)

      puts "CiJob: #{ci_job.inspect}"

      next if ci_job.finished?

      next create_ci_job(check_suite, result, bamboo_ci_ref, github_check) if ci_job.nil?

      update_ci_job_status(github_check, ci_job, result['state'])
    end
  end

  def create_ci_job(check_suite, result, bamboo_ci_ref, github_check)
    ci_job = CiJob.create(check_suite: check_suite, name: result.dig('plan', 'shortName'), job_ref: bamboo_ci_ref)

    puts ">>> Creating CiJob #{ci_job.inspect}, status: #{result['state']}"

    update_ci_job_status(github_check, ci_job, result['state'])
  end

  def update_ci_job_status(github_check, ci_job, state)
    url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{ci_job.job_ref}"
    output = {
      title: ci_job.name,
      summary: "Details at [#{url}](#{url})\nUnfortunately we were unable to access the execution results."
    }

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

sync = SingleSync.new
sync.perform(ARGV[0])
