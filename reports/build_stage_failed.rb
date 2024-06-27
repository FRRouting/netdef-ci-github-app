#  SPDX-License-Identifier: BSD-2-Clause
#
#  build_stage_failed.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../database_loader'
require_relative '../lib/helpers/configuration'

begin_date = ARGV[0]
end_date = ARGV[1]
author = ARGV[2]

check_suites = []

Stage
  .joins(:jobs, :check_suite)
  .where(stages: { name: 'Build' })
  .where(jobs: { created_at: [begin_date..end_date], status: %i[failure skipped] })
  .where(check_suites: { author: author })
  .each do |stage|
  message = "Check Suite ID: https://ci1.netdef.org/browse/#{stage.check_suite.bamboo_ci_ref}"
  check_suites << message unless check_suites.include? message
end

check_suites.each do |line|
  puts line
end
