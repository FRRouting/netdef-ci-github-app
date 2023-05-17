# frozen_string_literal: true

require 'logger'
require 'octokit'
require 'netrc'
require 'json'

require_relative 'api'

module BambooCi
  class PlanRun
    include Api

    attr_reader :ciKey
    attr_accessor :checks_run, :ci_variables

    def initialize(plan, payload, logger_level: Logger::INFO)
      @bamboo_plan = plan
      @pull_request = payload['pull_request']
      @ci_variables = []
      @logger = Logger.new($stdout)
      @logger.level = logger_level
    end

    def start_plan
      log_title

      @response = submit_pr_to_ci(@pull_request, @bamboo_plan, @ci_variables)

      case @response&.code.to_i
      when 200, 201
        success(@response)
      when 400..500
        failed(@response)
      when 0
        @logger.unknown 'HTTP Request error'
      else
        @logger.unknown "Unmapped HTTP error (Bamboo): #{@response&.code.to_i}\nPR: #{@pull_request.inspect}"
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
      @logger.debug ""
      @logger.debug "CI Submitted:"
      @logger.debug "#{ hash }"

      @ci_key = hash["buildResultKey"]

      comment = "GitHub Merge Request #{@number}\n"
      comment += "for GitHub Repo #{@pull_request['base']['repo']['full_name']}, branch #{@pull_request['base']['ref']}\n\n"
      comment += "Request to merge from #{@pull_request['head']['repo']['full_name']}\n"
      comment += "Merge Git Commit ID #{@pull_request['head']['sha']}"
      comment += " on top of base Git Commit ID #{@pull_request['base']['sha']}"

      response =  add_comment_to_ci(@ci_key, comment)
      debugPuts "Comment Submit response: #{response&.code}"

      200
    end

    def failed(response)
      @logger.debug ''
      @logger.debug "ci submission failed: #{response.body}"
      @logger.debug "Error #{response.code}"

      return 429 if response.body =~ /reached the maximum number of concurrent builds/

      response.code.to_i
    end

    def log_title
      @logger.debug "It's #{@pull_request['title']}"
      @logger.debug "Bamboo Plan:      #{@bamboo_plan}"
      @logger.debug "Github Repo:      #{@pull_request['base']['repo']['full_name']}"
      @logger.debug "Github Branch:    #{@pull_request['base']['ref']}"
      @logger.debug "Github Base SHA:  #{@pull_request['base']['sha']}"
      @logger.debug "Github Merge SHA: #{@pull_request['head']['sha']}"
      @logger.debug "Pull Req # is:    #{@number}"
    end
  end
end
