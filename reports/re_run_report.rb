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
      @result = { full: {}, partial: {} }
      AuditRetry
        .where(created_at: [begin_date..end_date])
        .each do |audit_retry|
        generate_result(audit_retry)
      end

      save_rerun_info(@result, output, filename)
    end

    private

    def generate_result(audit_retry)
      report_initializer(audit_retry)

      @result[audit_retry.retry_type.to_sym][audit_retry.check_suite.pull_request.github_pr_id][:total] += 1

      check_suite_detail(audit_retry)
    end

    def report_initializer(audit_retry)
      @result[audit_retry.retry_type.to_sym][audit_retry.check_suite.pull_request.github_pr_id] ||=
        { total: 0, check_suites: [] }
    end

    def check_suite_detail(audit_retry)
      @result[audit_retry.retry_type.to_sym][audit_retry.check_suite.pull_request.github_pr_id][:check_suites] <<
        {
          check_suite_id: audit_retry.check_suite.id,
          bamboo_job: audit_retry.check_suite.bamboo_ci_ref,
          github_username: audit_retry.github_username
        }
    end

    def save_rerun_info(result, output, filename)
      case output
      when 'json'
        File.write(filename, result.to_json)
      when 'file'
        File.open(filename, 'a') do |f|
          raw_output(result, file_descriptor: f)
        end
      else
        raw_output(result)
      end
    end

    def raw_output(result, file_descriptor: nil)
      result.each do |type, prs|
        print("\n#{type.capitalize} reruns", file_descriptor)
        prs.each do |pr, info|
          print("PR: #{pr} - Total: #{info[:total]}", file_descriptor)
          info[:check_suites].each do |cs|
            print("  - Check Suite: #{cs[:check_suite_id]}", file_descriptor)
            print("    - Bamboo Job: #{cs[:bamboo_job]}", file_descriptor)
            print("    - Github Username: #{cs[:github_username]}", file_descriptor)
          end
        end
      end
    end

    def print(line, file_descriptor)
      puts line
      file_descriptor&.write line
    end
  end
end

return unless __FILE__ == $PROGRAM_NAME

begin_date = ARGV[0]
end_date = ARGV[1]

Reports::ReRunReport.new.report(begin_date, end_date, output: ARGV[2], filename: ARGV[3])
