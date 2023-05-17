#!/usr/bin/env ruby

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

$bambooServer = '127.0.0.1'
$debugEnabled = 0
$debugLog = nil
$debugLogDir = '/home/githubchecks/debug'
$githubLogFile = '/home/githubchecks/githubAPILog.log'

def debugPuts(string)
  if $debugEnabled > 0
    if $debugLog != nil
      $debugLog.puts string
    end
    puts string
  end
end

def debugPP(var)
  if $debugEnabled > 0
    pp var, $debugLog
  end
  pp var
end

class GitHubHookServer < Sinatra::Base
  set :bind, '0.0.0.0'
  set :port, 4667
  set :show_exceptions, false

  helpers Sinatra::Payload

  get '/' do
    debugPuts ''
    debugPuts ''
    debugPuts "get Request at #{DateTime.now.strftime("%Y%jT%H%M%SZ")}"
    debugPuts '============================================================='
    debugPuts "#{ request.env }"
    content_type :text
    debugPuts "#{ JSON.pretty_generate(request.env) }"
    debugPuts '======= GET DONE ======== DONE ========== DONE ========='
    debugPuts 'RETURN: halt 401: Invalid request (1)'

    halt 401, 'Invalid request (1)'
  end

  get '/ping' do
    debugPuts 'RETURN: halt 200: Pong'

    halt 200, 'Pong'
  end

  post '/bamboo/update' do
    @payload_raw = request.body.read
    @rc = Netrc.read

    auth_signature

    @payload = JSON.parse(@payload_raw)

    github_check = Github::Check.new(@payload)

    case @payload['bamboo_ci_status']
    when 'in_progress'
      puts github_check.update(@payload['bamboo_ci_stage'], 'in_progress').inspect
    when 'success'
      github_check.success(@payload['bamboo_ci_stage'])
    when 'failed'
      github_check.failed(@payload['bamboo_ci_stage'])
    else
      github_check.failed(@payload['bamboo_ci_stage'])
    end

    halt 200
  end

  post '/*' do
    debugPuts ''
    debugPuts ''
    debugPuts "post Request at #{DateTime.now.strftime("%Y%jT%H%M%SZ")}"
    debugPuts '============================================================='
    debugPuts "#{ request.env }"
    content_type :text
    debugPuts "#{ JSON.pretty_generate(request.env) }"
    debugPuts '----------------------'
    request.body.rewind
    debugPuts "#{ JSON.pretty_generate(JSON.parse(request.body.read)) }"
    debugPuts '======= POST DONE ======== DONE ========== DONE ========='
    request.body.rewind

    @payload_raw = request.body&.read
    @rc = Netrc.read
    auth_signature

    case request.env['HTTP_X_GITHUB_EVENT'].downcase
    when 'ping'
      debugPuts 'Ping received - Pong sending'
      debugPuts 'RETURN: halt 200: PONG!'

      halt 200, 'PONG!'
    when 'pull_request'
      logger_level = $debugEnabled.positive? ? Logger::DEBUG: Logger::INFO

      build_plan = GitHub::BuildPlan.new(@payload_raw, logger_level: logger_level)
      resp = build_plan.create

      halt resp.first, resp.last
    when 'check_run'
      payload = JSON.parse(@payload_raw)
      message = "Check Run #{payload['check_run']['id']} (#{payload['check_run']['id']}) - #{payload['action']}"
      debugPuts(message)
      halt 200, 'OK'
    else
      puts "Unknown request #{request.env['HTTP_X_GITHUB_EVENT'].downcase}"
      halt 401, 'Invalid request (4)'
    end
  end

  run! if __FILE__ == $0
  exit
end
