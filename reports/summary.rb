#  SPDX-License-Identifier: BSD-2-Clause
#
#  summary.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../database_loader'
require_relative '../lib/helpers/configuration'

begin_date = ARGV[0]
end_date = ARGV[1]
new_prs = PullRequest.where(created_at: [begin_date..end_date])
new_prs_count = new_prs.size
new_exec_pr = CheckSuite.where(pull_request_id: new_prs.map(&:id)).size
total_exec_pr = CheckSuite.where(created_at: [begin_date..end_date]).size
total_skipped = CheckSuite.joins(:ci_jobs).where(ci_jobs: { status: %i[skipped cancelled] }).size
total_failure = CheckSuite.joins(:ci_jobs).where(ci_jobs: { status: %i[failure] }).size
total_success = CheckSuite.joins(:ci_jobs).where(ci_jobs: { status: %i[success] }).size
topotest_failure = TopotestFailure.where(created_at: [begin_date..end_date]).size
failures = TopotestFailure
           .where(created_at: ['2023-10-01 00:00:00'..])
           .group(:test_suite, :test_case)
           .limit(10)
           .count(:test_case)
           .sort_by { |_k, v| v }
           .reverse
           .to_h

build_errors = CiJob
               .where("name ILIKE '% build'")
               .where(created_at: [begin_date..end_date], status: %i[failure skipped])

build_errors_count = build_errors.size
build_errors_author = CheckSuite
                      .where(id: build_errors.map(&:check_suite_id).uniq)
                      .group(:author, :pull_request_id)
                      .limit(10)
                      .count('check_suites.author')
                      .sort_by { |_k, v| v }
                      .reverse
                      .map do |key, value|
                        author, pr_id = key
                        pr = PullRequest.find(pr_id)
                        { "#{author}: PR ##{pr.github_pr_id}": value }
                      end

puts "Report from #{begin_date} to #{end_date}\n\n"
puts "New PRs: #{new_prs_count}"
puts "CI executions (New PRs): #{new_exec_pr}"
puts "CI executions: #{total_exec_pr}"
puts "CI executions jobs - success: #{total_success}"
puts "CI executions jobs - failure: #{total_failure}"
puts "CI executions jobs - skipped / cancelled: #{total_skipped}"

puts "\nCI executions jobs - Build failure: #{build_errors_count}"
puts "Build Failure Author: \n\n"

build_errors_author.each do |entry|
  entry.each_pair do |key, value|
    puts "#{key} - #{value}"
  end
end

puts "\nTopoTests Failure: #{topotest_failure}"
puts "TopoTests Failure summarize:\n\n"

failures.each_pair do |key, value|
  puts "#{key.join(' ')} - #{value}"
end
