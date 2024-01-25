#  SPDX-License-Identifier: BSD-2-Clause
#
#  status.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Slack
  class Running
    def call(payload)
      @payload = payload

      github_user = @payload['github_user']

      pull_requests_running =
        PullRequest
        .joins(check_suites: :ci_jobs)
        .where(author: github_user)
        .where(check_suites: { ci_jobs: { status: %i[queued in_progress] } })
        .group('pull_requests.id')

      pull_requests_running.blank? ? 'No running PR' : "```#{to_table(pull_requests_running)}```"
    end

    def to_table(pull_requests)
      header =
        "|     PR ID     |                              URL                               | Tests Running or Queued |\n"
      header +=
        "| ------------- | -------------------------------------------------------------- | ----------------------- |\n"

      "#{header}#{table_entries(pull_requests).join("\n")}"
    end

    def table_entries(pull_requests)
      pull_requests.map do |pull_request|
        pr_id = "#{' ' * 6}#{pull_request.github_pr_id}"
        pr_id += calc_padding(pr_id, 13)

        url = "    https://github.com/#{pull_request.repository}/pull/#{pull_request.github_pr_id}"
        url += calc_padding(url, 62)

        "| #{pr_id} | #{url} | #{running_or_queued(pull_request.check_suites.last)} |"
      end
    end

    def running_or_queued(check_suite)
      total = check_suite.running_jobs.size.to_s

      total = "#{' ' * 10}#{total}"

      total + calc_padding(total, 23)
    end

    def calc_padding(str, max_size)
      ' ' * (max_size - str.size)
    end
  end
end
