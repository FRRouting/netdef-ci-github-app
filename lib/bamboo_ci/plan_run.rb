#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan_run.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require 'octokit'
require 'netrc'
require 'json'

require_relative 'api'

module BambooCi
  class PlanRun
    include Api

    attr_reader :ci_key
    attr_accessor :checks_run, :ci_variables

    def initialize(check_suite, logger_level: Logger::INFO)
      @logger_manager = []
      @logger_level = logger_level

      logger_class = Logger.new('github_plan_run.log', 0, 1_024_000)
      logger_class.level = logger_level

      logger_app = Logger.new('github_app.log', 1, 1_024_000)
      logger_app.level = logger_level

      @logger_manager << logger_class
      @logger_manager << logger_app

      logger(Logger::INFO, "BambooCi::PlanRun - CheckSuite: #{check_suite.inspect}")

      @check_suite = check_suite
      @ci_variables = []
    end

    def start_plan
      @response = submit_pr_to_ci(@check_suite, @ci_variables)

      case @response&.code.to_i
      when 200, 201
        success(@response)
      when 400..500
        failed(@response)
      when 0
        logger(Logger::UNKNOWN, 'HTTP Request error')
        418
      else
        logger(Logger::UNKNOWN, "Unmapped HTTP error (Bamboo): #{@response.code.to_i}\nPR: #{@check_suite.inspect}")
        failed(@response)
      end
    end

    def bamboo_reference
      return nil if @response.nil?

      JSON.parse(@response.body)['buildResultKey']
    end

    private

    def success(response)
      hash = JSON.parse(response.body)

      logger(Logger::DEBUG, "\nCI Submitted:\n#{hash}")

      @ci_key = hash['buildResultKey']

      response = generate_comment

      logger(Logger::DEBUG, "Comment Submit response: #{response.inspect}")

      200
    end

    def failed(response)
      logger(Logger::DEBUG, '')
      logger(Logger::DEBUG, "ci submission failed: #{response.body}")
      logger(Logger::DEBUG, "Error #{response.code}")

      return 429 if response.body.include?('reached the maximum number of concurrent builds')

      response.code.to_i
    end

    def generate_comment
      comment = "GitHub Merge Request #{@check_suite.pull_request.github_pr_id}\n"
      comment += "for GitHub Repo #{@check_suite.pull_request.repository}, " \
                 "branch #{@check_suite.work_branch}\n\n"
      comment += "Request to merge from #{@check_suite.pull_request.repository}\n"
      comment += "Merge Git Commit ID #{@check_suite.commit_sha_ref}"
      comment += " on top of base Git Commit ID #{@check_suite.base_sha_ref}"

      logger(Logger::DEBUG, comment)

      add_comment_to_ci(@ci_key, comment)
    end

    def logger(severity, message)
      @logger_manager.each do |logger_object|
        logger_object.add(severity, message)
      end
    end
  end
end
