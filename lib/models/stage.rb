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
  enum :status, { queued: 0, in_progress: 1, success: 2, cancelled: -1, failure: -2, skipped: -3 }

  has_many :jobs, class_name: 'CiJob'
  has_many :audit_statuses, as: :auditable
  belongs_to :configuration, class_name: 'StageConfiguration', foreign_key: 'stage_configuration_id'
  belongs_to :check_suite

  default_scope -> { order(id: :asc) }, all_queries: true

  scope :next_stage, ->(current_position) { where(configuration: { position: current_position + 1 }) }
  scope :next_stages, ->(current_position) { where(configuration: { position: [(current_position + 1)..] }) }

  def update_execution_time
    started = audit_statuses.find_by(status: :in_progress)
    finished = audit_statuses.find_by(status: %i[success failure])

    return if started.nil? || finished.nil?

    update(execution_time: finished.created_at - started.created_at)
  end

  def running?
    jobs.where(status: %i[queued in_progress]).any?
  end

  def finished?
    jobs.where(status: %w[queued in_progress]).empty?
  end

  def enqueue(github, output: {}, agent: 'Github')
    # A new check run is already queued, so no update is needed right after creating it.
    check_run = github.create(github_stage_full_name(name), output: output)
    update(check_ref: check_run.id, status: :queued)
    AuditStatus.create(auditable: self, status: :queued, agent: agent, created_at: Time.now)
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
    ref = complete_check_run(github, :cancelled, output)

    update(status: :cancelled, check_ref: ref)
    AuditStatus.create(auditable: self, status: :cancelled, agent: agent, created_at: Time.now)
    notification
  end

  def failure(github, output: {}, agent: 'Github')
    ref = complete_check_run(github, :failure, output)

    update(status: :failure, check_ref: ref)
    AuditStatus.create(auditable: self, status: :failure, agent: agent, created_at: Time.now)
    notification
  end

  def success(github, output: {}, agent: 'Github')
    ref = complete_check_run(github, :success, output)

    reload
    update(status: :success, check_ref: ref)
    AuditStatus.create(auditable: self, status: :success, agent: agent, created_at: Time.now)
    notification
  end

  private

  # Completes the stage's own check run. Creating a new one each time left the old one in_progress next to
  # it forever, so a new check run is only created when there is none or GitHub refuses the update
  # (Github::Check answers {} once its retries are spent).
  def complete_check_run(github, conclusion, output)
    return check_ref if !check_ref.nil? and github.public_send(conclusion, check_ref, output).present?

    check_run = github.create(github_stage_full_name(name))
    github.public_send(conclusion, check_run.id, output)

    check_run.id
  end

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
    in_progress_jobs = in_progress.map do |job|
      "- **#{job.name}** -> https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{job.job_ref}\n"
    end.join("\n")

    url = "https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{check_suite.bamboo_ci_ref}"
    { title: "#{name} summary", summary: "#{header}#{in_progress_jobs}\nDetails at [#{url}](#{url})" }
  end

  def mount_in_progress_jobs(jobs)
    jobs.where(status: :in_progress).map do |job|
      "- **#{job.name}** -> https://#{url}/browse/#{job.job_ref}\n"
    end.join("\n")
  end
end
