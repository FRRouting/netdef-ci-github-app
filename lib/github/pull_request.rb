# frozen_string_literal: true

require 'logger'
require 'jwt'
require 'base64'
require_relative '../bamboo_ci/plan_run'
require_relative '../github/check'

module GitHub
  # This class is responsible for generating the Bamboo CI request and generating the GitHub Checks.
  class PullRequest
    def initialize(payload_raw, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = JSON.parse(payload_raw)
      @github_check = Github::Check.new(@payload)

      @logger.debug 'This is a Pull Request - proceed with branch check'
      fetch_plan
    end

    def valid_pull_request?
      !@payload.nil? and
        !@payload['pull_request'].nil? and
        !@payload['pull_request']['base'].nil? and
        !@payload['pull_request']['base']['ref'].nil?
    end

    def start
      start_logs

      unless %w[opened synchronize reopened].include? @payload['action']
        @logger.info "Action is \"#{@payload['action']}\" - ignored"

        return [200, "Not dealing with action \"#{@payload['action']}\" for Pull Request"]
      end

      resp = process_pull_request

      github_logs(resp)

      case resp
      when 200, 201, 204
        @logger.info 'RETURN: halt 200: Pull processed'
        [200, 'Pull processed']
      when 429
        @logger.info 'RETURN: halt 429: Sorry, too busy right now to accept another request'
        [429, 'Sorry, too busy right now to accept another request']
      else
        @logger.info 'RETURN: halt error: Internal error'
        [resp, 'Internal error']
      end
    end

    private

    def start_logs
      @logger.debug ''
      @logger.debug ''
      @logger.debug "post is PULL REQUEST for plan #{@plan}"
      @logger.debug "Action is #{@payload['action']}"
    end

    def github_logs(resp)
      ci_user = '(unknown)'
      ci_user = @payload.dig('pull_request', 'user', 'login') if valid_user?

      ci_timestamp = @payload.dig('pull_request', 'updated_at')

      @logger.debug 'CI Command is  PULL_REQUEST'
      @logger.debug "     note is   #{@payload['action']}"
      @logger.debug "     timestamp #{ci_timestamp}"
      @logger.debug "     user      #{ci_user}"

      github_log = File.open('/home/githubchecks/githubAPILog.log', 'a')
      github_log.puts "#{ci_timestamp}, PR#{@payload['pull_request']['number']}, " \
                      "PULL_REQUEST, #{ci_user}, " \
                      "#{@payload['action']}, #{@bamboo_plan_run.ciKey}, #{resp}"
      github_log.close
    end

    def valid_user?
      !@payload.dig('pull_request', 'user', 'login').nil?
    end

    def create_check_runs
      ci_vars = []

      ci_vars << { id: @github_check.app_id, name: 'app_id' }
      ci_vars << { id: @github_check.installation_id, name: 'app_installation_id' }
      ci_vars << { id: Base64.encode64(File.read('private_key.pem')), name: 'app_secret' }

      ci_vars
    end

    # Action "opened": New pull request is opened
    # Action "synchronize": Pull request is updated
    def process_pull_request
      @bamboo_plan_run = BambooCi::PlanRun.new(@plan,
                                               @payload,
                                               logger_level: @logger.level)

      @bamboo_plan_run.checks_run = create_check_runs

      @bamboo_plan_run.create
    end

    def fetch_plan
      # TODO: - Change to FRR plans
      @plan = case @payload['pull_request']['head']['repo']['full_name']
              when 'RodrigoMNardi/bind_manager'
                'TESTING-FRRCRAS'
              else
                'TESTING-FRRCRASHARM'
              end
    end
  end
end
