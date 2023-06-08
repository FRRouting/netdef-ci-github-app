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

require_relative 'lib/helpers/sinatra_payload'
require_relative 'lib/github/pull_request'
require_relative 'lib/github/check'
require_relative 'database_loader'

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
      puts github_check.update(@payload['bamboo_ci_stage'], 'in_progress').inspect
    when 'success'
      github_check.success(@payload['bamboo_ci_stage'])
    else
      github_check.failed(@payload['bamboo_ci_stage'])
    end

    halt 200
  end

  post '/*' do
    content_type :text

    logger_level = Logger::DEBUG
    logger = Logger.new($stdout)
    logger.level = logger_level

    logger.debug ''
    logger.debug ''
    logger.debug "post Request at #{DateTime.now.strftime('%Y%jT%H%M%SZ')}"
    logger.debug '============================================================='
    logger.debug request.env.to_s

    logger.debug JSON.pretty_generate(request.env).to_s
    logger.debug '----------------------'
    request.body.rewind
    logger.debug JSON.pretty_generate(JSON.parse(request.body.read)).to_s
    logger.debug '======= POST DONE ======== DONE ========== DONE ========='
    request.body.rewind

    @payload_raw = request.body&.read
    auth_signature

    case request.env['HTTP_X_GITHUB_EVENT'].downcase
    when 'ping'
      logger.debug 'Ping received - Pong sending'
      logger.debug 'RETURN: halt 200: PONG!'

      halt 200, 'PONG!'
    when 'pull_request'
      build_plan = GitHub::BuildPlan.new(@payload_raw, logger_level: logger_level)
      resp = build_plan.create

      halt resp.first, resp.last
    when 'check_run'
      payload = JSON.parse(@payload_raw)
      message = "Check Run #{payload['check_run']['id']} (#{payload['check_run']['id']}) - #{payload['action']}"
      logger.debug(message)
      halt 200, 'OK'
    else
      logger.error "Unknown request #{request.env['HTTP_X_GITHUB_EVENT'].downcase}"
      halt 401, 'Invalid request (4)'
    end
  end

  run! if __FILE__ == $PROGRAM_NAME
  exit
end
