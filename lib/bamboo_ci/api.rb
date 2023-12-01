#  SPDX-License-Identifier: BSD-2-Clause
#
#  api.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'net/http'
require 'net/https'
require 'netrc'
require 'json'
require 'multipart/post'

require_relative '../helpers/request'

module BambooCi
  module Api
    include GitHubApp::Request

    def fetch_executions(plan)
      get_request(URI("https://127.0.0.1/rest/api/latest/search/jobs/#{plan}"))
    end

    def get_status(id)
      get_request(URI("https://127.0.0.1/rest/api/latest/result/#{id}?expand=stages.stage.results,artifacts"))
    end

    def submit_pr_to_ci(check_suite, ci_variables)
      url = "https://127.0.0.1/rest/api/latest/queue/#{check_suite.pull_request.plan}"

      url += custom_variables(check_suite)

      ci_variables.each do |variable|
        url += "&bamboo.variable.github_#{variable[:name]}=#{variable[:value]}"
      end

      logger(Logger::DEBUG, "Submission URL:\n  #{url}")

      # Fetch Request
      post_request(URI(url))
    end

    def custom_variables(check_suite)
      "?customRevision=#{check_suite.merge_branch}" \
        "&bamboo.variable.github_repo=#{check_suite.pull_request.repository.gsub('/', '%2F')}" \
        "&bamboo.variable.github_pullreq=#{check_suite.pull_request.github_pr_id}" \
        "&bamboo.variable.github_branch=#{check_suite.merge_branch}" \
        "&bamboo.variable.github_merge_sha=#{check_suite.commit_sha_ref}" \
        "&bamboo.variable.github_base_sha=#{check_suite.base_sha_ref}"
    end

    def add_comment_to_ci(key, comment)
      url = "https://127.0.0.1/rest/api/latest/result/#{key}/comment"

      logger(Logger::DEBUG, "Comment Submission URL:\n  #{url}")

      # Fetch Request
      post_request(URI(url), body: "<comment><content>#{comment}</content></comment>")
    end

    def logger(severity, message)
      return if @logger_manager.nil?

      @logger_manager.each do |logger_object|
        logger_object.add(severity, message)
      end
    end
  end
end
