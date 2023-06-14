# frozen_string_literal: true

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
      @check_suite = check_suite
      @ci_variables = []
      @logger = Logger.new($stdout)
      @logger.level = logger_level
    end

    def start_plan
      @response = submit_pr_to_ci(@check_suite, @ci_variables)

      case @response&.code.to_i
      when 200, 201
        success(@response)
      when 400..500
        failed(@response)
      when 0
        @logger.unknown 'HTTP Request error'
        418
      else
        @logger.unknown "Unmapped HTTP error (Bamboo): #{@response&.code.to_i}\nPR: #{@check_suite.inspect}"
        failed(@response)
      end
    end

    def bamboo_reference
      return nil if @response.nil?

      JSON.parse(@response.body)['buildResultKey']
    end

    def fetch_stages
      resp = get_status(@ci_key)

      resp['stages']['stage'].map { |entry| entry['name'] }
    end

    private

    def success(response)
      hash = JSON.parse(response.body)

      @logger.debug "\nCI Submitted:\n#{hash}"

      @ci_key = hash['buildResultKey']

      response = generate_comment

      @logger.debug "Comment Submit response: #{response&.code}"

      200
    end

    def failed(response)
      @logger.debug ''
      @logger.debug "ci submission failed: #{response.body}"
      @logger.debug "Error #{response.code}"

      return 429 if response.body.include?('reached the maximum number of concurrent builds')

      response.code.to_i
    end

    def generate_comment
      comment = "GitHub Merge Request #{@check_suite.pull_request.github_pr_id.split('/').last}\n"
      comment += "for GitHub Repo #{@check_suite.pull_request.repository}, " \
                 "branch #{@check_suite.work_branch}\n\n"
      comment += "Request to merge from #{@check_suite.pull_request.repository}\n"
      comment += "Merge Git Commit ID #{@check_suite.commit_sha_ref}"
      comment += " on top of base Git Commit ID #{@check_suite.base_sha_ref}"

      @logger.debug comment

      add_comment_to_ci(@ci_key, comment)
    end
  end
end
