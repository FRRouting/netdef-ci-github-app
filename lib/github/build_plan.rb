#  SPDX-License-Identifier: BSD-2-Clause
#
#  build_plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'

require_relative '../../database_loader'
require_relative '../bamboo_ci/stop_plan'
require_relative '../bamboo_ci/running_plan'
require_relative '../bamboo_ci/plan_run'
require_relative 'check'
require_relative 'build/action'
require_relative 'user_info'

module Github
  class BuildPlan
    def initialize(payload, logger_level: Logger::INFO)
      @logger = Logger.new($stdout)
      @logger.level = logger_level

      @payload = payload

      raise "Invalid payload:\n#{payload}" if @payload.nil? or @payload.empty?

      @logger.debug 'This is a Pull Request - proceed with branch check'
    end

    def create
      unless %w[opened synchronize reopened].include? @payload['action']
        @logger.warn "Action is \"#{@payload['action']}\" - ignored"

        return [405, "Not dealing with action \"#{@payload['action']}\" for Pull Request"]
      end

      # Fetch for a Pull Request at database
      @logger.info 'Fetching / Creating a pull request'
      fetch_pull_request

      Github::Build::PlanRun.new(@pull_request, @payload).build
    end

    private

    def fetch_pull_request
      @pull_request = PullRequest.find_by(github_pr_id: github_pr, repository: @payload.dig('repository', 'full_name'))

      return create_pull_request if @pull_request.nil?

      @pull_request.update(branch_name: @payload.dig('pull_request', 'head', 'ref'))

      add_plans
    end

    def github_pr
      @payload['number']
    end

    def create_pull_request
      @pull_request =
        PullRequest.create(
          author: @payload.dig('pull_request', 'user', 'login'),
          github_pr_id: github_pr,
          branch_name: @payload.dig('pull_request', 'head', 'ref'),
          repository: @payload.dig('repository', 'full_name'),
          plan: fetch_plan_name
        )

      add_plans

      Github::UserInfo.new(@payload.dig('pull_request', 'user', 'id'), pull_request: @pull_request)
    end

    def fetch_plan_name
      plan = Plan.find_by(github_repo_name: @payload.dig('repository', 'full_name'))

      return plan.bamboo_ci_plan_name unless plan.nil?

      # Default plan
      'TESTING-FRRCRAS'
    end

    def add_plans
      return if @pull_request.nil?

      @pull_request.plans = []

      Plan.where(github_repo_name: @payload.dig('repository', 'full_name')).each do |plan|
        @pull_request.plans << plan unless @pull_request.plans.include?(plan)
      end

      @pull_request.save
    end
  end
end
