#  SPDX-License-Identifier: BSD-2-Clause
#
#  stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class Stage < ActiveRecord::Base
  enum status: { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }

  has_many :jobs, class_name: 'CiJob'
  belongs_to :configuration, class_name: 'StageConfiguration', foreign_key: 'stage_configuration_id'
  belongs_to :check_suite

  def running?
    jobs.where(status: %i[queued in_progress]).any?
  end

  def previous_stage
    position = configuration&.position.to_i
    check_suite.stages.joins(:configuration).find_by(configuration: { position: position - 1 })
  end

  def finished?
    jobs.where(status: %w[queued in_progress]).empty?
  end

  def enqueue(github, output: {})
    check_run = github.create(github_stage_full_name(name))
    github.queued(check_run.id, output)
    update(check_ref: check_run.id, status: :queued)
  end

  def in_progress(github, output: output_in_progress, job: nil)
    create_github_check(github)
    github.in_progress(check_ref, output)

    in_progress_notification if !job.nil? and first_job == job

    update(status: :in_progress)
  end

  def cancelled(github, output: {})
    create_github_check(github)
    github.cancelled(check_ref, output)
    update(status: :cancelled)
    notification
  end

  def failure(github, output: {})
    create_github_check(github)
    github.failure(check_ref, output)
    update(status: :failure)
    notification
  end

  def success(github, output: {})
    create_github_check(github)
    github.success(check_ref, output)
    update(status: :success)
    notification
  end

  private

  def in_progress_notification
    SlackBot.instance.stage_in_progress_notification(self)
  end

  def first_job
    jobs
      .reload
      .where.not(status: %i[success failure cancelled skipped])
      .order('ci_jobs.id')
      .first
  end

  def notification
    SlackBot.instance.stage_finished_notification(self)
  end

  def create_github_check(github)
    return unless check_ref.nil?

    check_run = github.create(github_stage_full_name(name))
    update(check_ref: check_run.id)
  end

  def github_stage_full_name(name)
    "[CI] #{name}"
  end

  def output_in_progress
    in_progress = jobs.where(status: :in_progress)

    header = ":arrow_right: Jobs in progress: #{in_progress.size}/#{jobs.size}\n\n"
    in_progress_jobs = jobs.where(status: :in_progress).map do |job|
      "- **#{job.name}** -> https://ci1.netdef.org/browse/#{job.job_ref}\n"
    end.join("\n")

    url = "https://ci1.netdef.org/browse/#{check_suite.bamboo_ci_ref}"
    { title: "#{name} summary", summary: "#{header}#{in_progress_jobs}\nDetails at [#{url}](#{url})" }
  end
end
