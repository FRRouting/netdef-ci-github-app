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
require_relative '../lib/github/plan_execution/finished'

class WatchDog
  def perform
    @logger = Logger.new('watch_dog.log', 0, 1_024_000)
    @logger.info '>>> Running watchdog'

    suites = check_suites

    @logger.info ">>> Suites that need to be updated: #{suites.size}"

    check(suites)

    @logger.info '>>> Stopping watchdog'
  end

  private

  def check(suites)
    suites.each do |check_suite|
      @logger.info ">>> Updating suite: #{check_suite.inspect}"
      Github::PlanExecution::Finished.new({ 'bamboo_ref' => check_suite.bamboo_ci_ref }).finished
    end
  end

  def check_suites
    CheckSuite.where(id: check_suites_fetch_map)
  end

  def check_suites_fetch_map
    CheckSuite
      .joins(:stages)
      .where(stages: { status: %w[queued in_progress] }, created_at: [..Time.now])
      .map(&:id)
      .uniq
  end
end

watch_dog = WatchDog.new
watch_dog.perform
