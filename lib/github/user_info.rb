#  SPDX-License-Identifier: BSD-2-Clause
#
#  user_info.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  class UserInfo
    def initialize(github_id, pull_request: nil, check_suite: nil, audit_retry: nil)
      @github_id = github_id
      @github = Github::Check.new nil
      @info = @github.fetch_username(github_id)

      @pull_request = pull_request
      @check_suite = check_suite
      @audit_retry = audit_retry

      @logger = GithubLogger.instance.create('github_user_info.log', Logger::INFO)

      @logger.info("Fetching user info for github_id: #{@github_id}")
      @logger.info(@info.inspect)

      fetch
    end

    private

    def fetch
      @user = GithubUser.find_by(github_id: @github_id)

      @logger.info("User: #{@user.inspect}")

      create_user_info if @user.nil?

      update_user_info

      add_pull_request unless @pull_request.nil?
      add_check_suite unless @check_suite.nil?
      add_retry unless @audit_retry.nil?
    end

    def add_pull_request
      @user.pull_requests << @pull_request
      @user.save
    end

    def add_check_suite
      @user.check_suites << @check_suite
      @user.save
    end

    def add_retry
      @user.audit_retries << @audit_retry
      @user.save
    end

    def update_user_info
      @user.update(
        github_login: @info[:login],
        github_username: @info[:name],
        github_email: @info[:email],
        github_type: @info[:type],
        organization_url: @info[:organizations_url],
        github_organization: @info[:company]
      )
    end

    def create_user_info
      @user =
        GithubUser.create(
          github_id: @github_id,
          github_login: @info[:login],
          github_username: @info[:name],
          github_email: @info[:email],
          github_type: @info[:type],
          organization_url: @info[:organizations_url],
          github_organization: @info[:company]
        )
    end
  end
end

