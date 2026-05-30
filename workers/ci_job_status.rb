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

class CiJobStatus
  def self.update(check_suite_id, ci_job_id)
    @logger = GithubLogger.instance.create('ci_job_status.log', Logger::INFO)
    @logger.info("CiJobStatus::Update: Checksuite #{check_suite_id} -> '#{ci_job_id}'")

    job = CiJob.find(ci_job_id)

    summary = Github::Build::Summary.new(job)
    summary.build_summary

    return unless job.finished?

    @logger.info("Github::PlanExecution::Finished: '#{job.check_suite.bamboo_ci_ref}'")

    finished = Github::PlanExecution::Finished.new({ 'bamboo_ref' => job.check_suite.bamboo_ci_ref })
    finished.finished
  end
end
