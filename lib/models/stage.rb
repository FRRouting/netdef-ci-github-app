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
  belongs_to :bamboo_stage_translations, class_name: 'BambooStageTranslation'
  belongs_to :check_suite

  def previous_stage
    position = bamboo_stage_translations.position
    check_suite.stages.joins(:bamboo_stage_translations).find_by(bamboo_stage_translations: { position: position - 1 })
  end

  def finished?
    jobs.where(status: %w[queued in_progress]).empty?
  end

  def create_check_run
    update(status: :queued)
  end

  def enqueue(github, output = {})
    check_run = github.create(github_stage_full_name(name))
    github.queued(check_run.id, output)
    update(check_ref: check_run.id, status: :queued)
  end

  def in_progress(github, output = output_in_progress)
    create_github_check(github)
    github.in_progress(check_ref, output)

    update(status: :in_progress)
  end

  def cancelled(github, output = {})
    create_github_check(github)
    github.cancelled(check_ref, output)

    update(status: :cancelled)
  end

  def failure(github, output = {})
    create_github_check(github)
    github.failure(check_ref, output)

    update(status: :failure)
  end

  def success(github, output = {})
    create_github_check(github)
    github.success(check_ref, output)

    update(status: :success)
  end

  def skipped(github, output = {})
    create_github_check(github)
    github.skipped(check_ref, output)

    update(status: :skipped)
  end

  private

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
