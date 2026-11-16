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
require_relative 'service_account'

module BambooCi
  module Api
    include GitHubApp::Request

    def fetch_executions(plan)
      PrometheusMetrics.track_bamboo('fetch_executions') do
        get_request(URI("https://127.0.0.1/rest/api/latest/search/jobs/#{plan}"))
      end
    end

    def get_status(id)
      PrometheusMetrics.track_bamboo('get_status') do
        get_request(URI("https://127.0.0.1/rest/api/latest/result/#{id}?expand=stages.stage.results,artifacts"))
      end
    end

    def submit_pr_to_ci(check_suite, plan, ci_variables)
      url = "https://127.0.0.1/rest/api/latest/queue/#{plan.bamboo_ci_plan_name}"

      url += custom_variables(check_suite)

      ci_variables.each do |variable|
        url += "&bamboo.variable.github_#{variable[:name]}=#{variable[:value]}"
      end

      logger(Logger::DEBUG, "Submission URL:\n  #{url}")

      PrometheusMetrics.track_bamboo('submit_plan') do
        post_request(URI(url.delete(' ')))
      end
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

      PrometheusMetrics.track_bamboo('add_comment') do
        post_request(URI(url.delete(' ')), body: "<comment><content>#{comment}</content></comment>")
      end
    end

    # With a service account every Bamboo request goes with its Bearer token instead of the ~/.netrc credentials.
    # A cached token Bamboo refuses with 401 (revoked, Bamboo restarted) is replaced and the request sent once more.
    # When no token can be obtained the request goes without credentials, so callers see Bamboo's 401.
    def send_request(uri, req, machine)
      account = BambooCi::ServiceAccount.instance
      return super unless account.configured?

      token, fresh = account.token_for(uri)
      resp = bearer_request(uri, req, token)
      token, resp = retry_with_new_token(uri, req, account, token, resp) if resp.code.to_i == 401 && !fresh

      log_token_refusal(req, resp, account) if [401, 403].include?(resp.code.to_i) && !token.nil?

      resp
    end

    # Only called for a cached token, which is never nil.
    def retry_with_new_token(uri, req, account, token, resp)
      account.forget(token)
      token, = account.token_for(uri)

      token.nil? ? [token, resp] : [token, bearer_request(uri, req, token)]
    end

    def bearer_request(uri, req, token)
      req['Authorization'] = "Bearer #{token}" unless token.nil?

      create_http(uri).request(req)
    end

    def log_token_refusal(req, resp, account)
      logger(Logger::ERROR,
             "Bamboo answered HTTP #{resp.code} to #{req.method} #{req.path} with the service account token " \
             "(requested scope: #{account.scope || '-'}; granted scope: #{account.granted_scope || '-'}): " \
             "#{BambooCi::ServiceAccount.summary(resp)}")
    end

    def logger(severity, message)
      return if @logger_manager.nil?

      @logger_manager.each do |logger_object|
        logger_object.add(severity, message)
      end
    end
  end
end
