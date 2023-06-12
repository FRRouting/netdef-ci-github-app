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
require_relative 'lib/helpers/sinatra_payload'

class GitHubHookServer < Sinatra::Base
  set :bind, '0.0.0.0'
  set :port, 4667
  set :show_exceptions, false

  helpers Sinatra::Payload

  get '/' do
    content_type :text
    logger = Logger.new($stdout)
    logger.level = Logger::INFO

    logger.debug ''
    logger.debug ''
    logger.debug "get Request at #{DateTime.now.strftime('%Y%jT%H%M%SZ')}"
    logger.debug '============================================================='
    logger.debug request.env.to_s
    logger.debug JSON.pretty_generate(request.env).to_s
    logger.debug '======= GET DONE ======== DONE ========== DONE ========='
    logger.debug 'RETURN: halt 401: Invalid request (1)'

    halt 401, 'Invalid request (1)'
  end

  get '/ping' do
    halt 200, 'Pong'
  end

  post '/bamboo/update' do
    @payload_raw = request.body.read

    auth_signature

    @payload = JSON.parse(@payload_raw)

    github_check = Github::Check.new(@payload)

    case @payload['bamboo_ci_status']
    when 'in_progress'
      github_check.update(@payload['bamboo_ci_stage'], 'in_progress')
    when 'success'
      github_check.success(@payload['bamboo_ci_stage'])
    else
      github_check.failed(@payload['bamboo_ci_stage'])
    end

    halt 200
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
      logger.debug('-' * 80)
      logger.debug "\n#{JSON.pretty_generate(JSON.parse(body))}"
      logger.debug '======= POST DONE ========'
    end
  end

  run! if __FILE__ == $PROGRAM_NAME
  exit
end
