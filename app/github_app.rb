#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_app.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

# !/usr/bin/env ruby

require 'logger'
require 'net/http'
require 'net/https'
require 'json'
require 'sinatra'
require 'octokit'
require 'netrc'
require 'date'
require 'yaml'

require_relative '../config/setup'

require_relative '../lib/github/build_plan'
require_relative '../lib/github/check'
require_relative '../lib/github/re_run'
require_relative '../lib/github/retry'
require_relative '../lib/github/update_status'
require_relative '../lib/helpers/sinatra_payload'

class GithubApp < Sinatra::Base
  set :bind, '0.0.0.0'
  set :port, 4667
  set :show_exceptions, false

  helpers Sinatra::Payload

  class << self
    def sinatra_logger_level
      GitHubApp::Configuration.instance.reload
      @sinatra_logger_level = GitHubApp::Configuration.instance.debug? ? Logger::DEBUG : Logger::INFO
    end

    attr_writer :sinatra_logger_level
  end

  get '/ping' do
    halt 200, 'Pong'
  end

  post '/update/status' do
    logger = Logger.new('github_app.log', 1, 1_024_000)
    logger.level = GithubApp.sinatra_logger_level

    @payload_raw = request.body.read
    @payload = JSON.parse(@payload_raw)

    logger.debug "Received event UpdateStatus: #{@payload}"

    authenticate_request

    github = Github::UpdateStatus.new(@payload)

    halt github.update
  end

  post '/*' do
    content_type :text

    logger = Logger.new('github_app.log', 1, 1_024_000)
    logger.level = GithubApp.sinatra_logger_level

    request.body.rewind
    body = request.body.read
    log_header(logger, body)

    @payload_raw = body
    payload = JSON.parse(@payload_raw)

    authenticate_request

    logger.debug "Received event: #{request.env['HTTP_X_GITHUB_EVENT']}"

    case request.env['HTTP_X_GITHUB_EVENT'].downcase
    when 'ping'
      logger.debug 'Ping received - Pong sending'
      logger.debug 'RETURN: halt 200: PONG!'

      halt 200, 'PONG!'
    when 'pull_request'
      build_plan = Github::BuildPlan.new(payload, logger_level: GithubApp.sinatra_logger_level)
      resp = build_plan.create

      halt resp.first, resp.last
    when 'check_run'
      logger.debug "Check Run #{payload.dig('check_run', 'id')} - #{payload['action']}"

      halt 200, 'OK' unless payload['action'].downcase.match?('rerequested')

      re_run = Github::Retry.new(payload, logger_level: GithubApp.sinatra_logger_level)
      halt re_run.start
    when 'installation'
      logger.debug '>>> Received a new installation policy'
      halt 202, 'Updated'
    when 'issue_comment'
      logger.debug '>>> Received a new issue comment'

      halt Github::ReRun.new(payload, logger_level: GithubApp.sinatra_logger_level).start
    else
      logger.debug "Unknown request #{request.env['HTTP_X_GITHUB_EVENT'].downcase}"
      halt 401, 'Invalid request (4)'
    end
  end

  helpers do
    def log_header(logger, body)
      logger.debug "\n\npost Request at #{DateTime.now.strftime('%Y%jT%H%M%SZ')}"
      logger.debug '=' * 80
      logger.debug "#{request.env}\n#{JSON.pretty_generate(request.env)}"
      logger.debug '-' * 80
      logger.debug "\n#{JSON.pretty_generate(JSON.parse(body))}"
      logger.debug '======= POST DONE ========'
    end
  end

  # :nocov:
  run! if __FILE__ == $PROGRAM_NAME
  # :nocov:
end
