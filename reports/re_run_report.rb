#  SPDX-License-Identifier: BSD-2-Clause
#
#  rerun_report.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'json'
require_relative '../database_loader'

module Reports
  class ReRunReport
    def report(begin_date, end_date, output: 'print', filename: 'rerun_report.json')
      result = rerun_comment(begin_date, end_date)
      save_rerun_info(result, output, filename, '>>> ReRuns Comments')
      result = rerun_partial(begin_date, end_date)
      save_rerun_info(result, output, filename, '>>> ReRuns Partial')
    end

    private
    
    def rerun_comment(begin_date, end_date)
        CheckSuite
        .where(re_run: true)
        .where(created_at: [begin_date..end_date])
        .group(:author, :pull_request_id)
        .order('count_check_suites_pull_request_id DESC')
        .count('check_suites.pull_request_id')
    end

    def rerun_partial(begin_date, end_date)
        CheckSuite
        .where.not(retry: 0)
        .where(created_at: [begin_date..end_date])
        .group(:author, :pull_request_id)
        .order('sum_check_suites_retry DESC')
        .sum('check_suites.retry')
    end

    def save_rerun_info(result, output, filename, title)
      puts result.inspect
      case output
      when 'print'
        raw_output(result)
      when 'json'
        File.write(filename, json_output(result).to_json)
      when 'file'
        File.open(filename, 'a') do |f|
          f.write "#{title}\n"
          raw_output(result, file_descriptor: f)
        end
      else
        puts result
      end
    end

    def raw_output(result, file_descriptor: nil)
      json_output(result).each_pair do |author, data|
        line = "#{author}: ReRuns #{data[:total]} - Pull Requests details #{data[:pull_requests].inspect}\n"
        puts line
        file_descriptor&.write(line)
      end
    end

    def json_output(result)
      json_obj = {}
      result.each do |entry|
        author, pr_id = entry[0]
        pr = PullRequest.find(pr_id)

        if json_obj[author]
          json_obj[author][:pull_requests] << { pr.github_pr_id => entry[1] }
          json_obj[author][:total] = json_obj[author][:total] + entry[1]
        else
          json_obj[author] = { total: entry[1] }
          json_obj[author][:pull_requests] = [{ pr.github_pr_id => entry[1] }]
        end
      end

      json_obj
    end
  end
end

return unless __FILE__ == $0

begin_date = ARGV[0]
end_date = ARGV[1]

Reports::ReRunReport.new.report(begin_date, end_date, output: ARGV[2], filename: ARGV[3])
