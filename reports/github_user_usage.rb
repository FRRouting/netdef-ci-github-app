#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_user_usage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../database_loader'

ActiveRecord::Base.logger = Logger.new('/dev/null')

user = GithubUser.find_by_github_login(ARGV[0])

if user.pull_requests.empty?
  puts "No pull requests found for user: #{user.github_login}"
else
  puts "Pull Requests for user: #{user.github_login}"
  user.pull_requests.each do |pr|
    puts "Pull Request: https://github.com/FRRouting/frr/pull/#{pr.github_pr_id}"
  end
end

if user.check_suites.empty?
  puts "No check suites found for user: #{user.github_login}"
else
  puts "Check Suites for user: #{user.github_login}"
  user.check_suites.each do |cs|
    puts "Check Suite: https://#{GitHubApp::Configuration.instance.ci_url}/browse/#{cs.bamboo_ci_ref}"
  end
end

if user.audit_retries.empty?
  puts "No audit retries found for user: #{user.github_login}"
else
  puts "Audit Retries for user: #{user.github_login}"
  user.audit_retries.each do |ar|
    puts "Audit Retry: #{ar.retry_type} at #{ar.created_at}"
  end
end
