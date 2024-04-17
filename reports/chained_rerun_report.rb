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
require 'csv'
require_relative '../database_loader'

module Reports
  class ChainedRerun
    def report(begin_date, end_date, output: 'print', filename: 'rerun_report.json')
      @result = {}
      @offenders = []

      CheckSuite
        .left_joins(:audit_retries)
        .where.not(check_suites: { cancelled_previous_check_suite_id: nil })
        .where(created_at: [begin_date..end_date])
        .order(:created_at)
        .group_by(&:pull_request_id)
        .each_pair do |pull_request_id, chained_check_suites|
        generate_result(pull_request_id, chained_check_suites)
      end
    end

    private

    def generate_result(pull_request_id, chained_check_suites)
      @local_chained = {}
      @chain = 1

      create_paths(chained_check_suites)

      puts "Pull Request ID: #{pull_request_id}"
      @local_chained.each_pair do |_c, path|
        puts path.reverse.join(' -> ')
      end
    end

    def create_paths(chained_check_suites)
      chained_check_suites.reverse_each do |check_suite|
        initialize_or_add(check_suite)

        if chained_check_suites.map(&:id).include?(check_suite.cancelled_previous_check_suite_id)
          @local_chained[@chain] << check_suite.cancelled_previous_check_suite_id
        else
          @local_chained[@chain] << CheckSuite.find(check_suite.cancelled_previous_check_suite_id).id
          @chain += 1
        end
      end
    end

    def initialize_or_add(check_suite)
      @local_chained[@chain] ||= []
      @local_chained[@chain] << check_suite.id unless @local_chained[@chain].include? check_suite.id
    end
  end
end

return unless __FILE__ == $PROGRAM_NAME

ActiveRecord::Base.logger = Logger.new('/dev/null')

begin_date = ARGV[0]
end_date = ARGV[1]

Reports::ChainedRerun.new.report(begin_date, end_date, output: ARGV[2], filename: ARGV[3])
