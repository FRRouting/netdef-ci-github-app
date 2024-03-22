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
  has_many :audit_statuses, as: :auditable
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

  def enqueue(github, output: {}, agent: 'Github')
    check_run = github.create(github_stage_full_name(name))
    github.queued(check_run.id, output)
    AuditStatus.create(auditable: self, status: :queued, agent: agent, created_at: Time.now)
    update(check_ref: check_run.id, status: :queued)
  end

  def in_progress(github, output: output_in_progress, agent: 'Github')
    return if in_progress?

    create_github_check(github)
    github.in_progress(check_ref, output)

    AuditStatus.create(auditable: self, status: :in_progress, agent: agent, created_at: Time.now)
    update(status: :in_progress)

    in_progress_notification
  end

  def update_output(github, output: output_in_progress)
    github.in_progress(check_ref, output)
  end

  def cancelled(github, output: {}, agent: 'Github')
    return if cancelled?

    create_github_check(github)
    github.cancelled(check_ref, output)
    update(status: :cancelled)
    AuditStatus.create(auditable: self, status: :cancelled, agent: agent, created_at: Time.now)
    notification
  end

  def failure(github, output: {}, agent: 'Github')
    return if failure?

    create_github_check(github)
    github.failure(check_ref, output)
    update(status: :failure)
    AuditStatus.create(auditable: self, status: :failure, agent: agent, created_at: Time.now)
    notification
  end

  def success(github, output: {}, agent: 'Github')
    return if success?

    create_github_check(github)
    github.success(check_ref, output)
    update(status: :success)
    AuditStatus.create(auditable: self, status: :success, agent: agent, created_at: Time.now)
    notification
  end

  def refresh_reference(github, agent: 'Github')
    check_run = github.create(github_stage_full_name(name))
    update(check_ref: check_run.id)
    AuditStatus.create(auditable: self, status: :refresh, agent: agent, created_at: Time.now)
  end

  def failure_jobs_output
    jobs.where(status: :failure).map do |job|
      "#{job.name} - #{job.topotest_failures.map(&:to_h)}"
    end
  end

  private

  def in_progress_notification
    SlackBot.instance.stage_in_progress_notification(self)
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
