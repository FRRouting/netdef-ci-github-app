#!/usr/bin/env ruby
# frozen_string_literal: true

require 'logger'
require 'net/http'
require 'net/https'
require 'json'
require 'sinatra'
require 'octokit'
require 'netrc'
require 'date'

require_relative 'database_loader'
require_relative 'lib/github/build_plan'
require_relative 'lib/github/check'
require_relative 'lib/github/retry'
require_relative 'lib/github/update_status'
require_relative 'lib/helpers/sinatra_payload'

class GitHubHookServer < Sinatra::Base
  set :bind, '0.0.0.0'
  set :port, 4667
  set :show_exceptions, false

  helpers Sinatra::Payload

  get '/ping' do
    halt 200, 'Pong'
  end

  post '/update/status' do
    logger_level = Logger::INFO
    logger = Logger.new($stdout)
    logger.level = logger_level

    @payload_raw = request.body.read
    @payload = JSON.parse(@payload_raw)

    logger.warn "Received event UpdateStatus: #{@payload}"

    auth_signature

    github = Github::UpdateStatus.new(@payload)

    halt github.update
  end

  post '/*' do
    content_type :text

    logger_level = Logger::INFO
    logger = Logger.new($stdout)
    logger.level = logger_level

    request.body.rewind
    body = request.body.read
    log_header(logger, body)

    @payload_raw = body
    payload = JSON.parse(@payload_raw)
    auth_signature

    logger.warn "Received event: #{request.env['HTTP_X_GITHUB_EVENT']}"

    case request.env['HTTP_X_GITHUB_EVENT'].downcase
    when 'ping'
      logger.debug 'Ping received - Pong sending'
      logger.debug 'RETURN: halt 200: PONG!'

      halt 200, 'PONG!'
    when 'pull_request'
      build_plan = GitHub::BuildPlan.new(payload, logger_level: logger_level)
      resp = build_plan.create

      halt resp.first, resp.last
    when 'check_run'
      logger.level = Logger::DEBUG
      logger.debug "Check Run #{payload['check_run']['id']} (#{payload['check_run']['id']}) - #{payload['action']}"
      logger.debug payload['action']
      logger.debug payload['action'].downcase.match?('rerequested')

      if payload['action'].downcase.match?('rerequested')
        re_run = GitHub::Retry.new(payload, logger_level: logger_level)
        halt re_run.start
      end

      halt 200, 'OK'
    else
      logger.error "Unknown request #{request.env['HTTP_X_GITHUB_EVENT'].downcase}"
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

  run! if __FILE__ == $PROGRAM_NAME
  exit
end
