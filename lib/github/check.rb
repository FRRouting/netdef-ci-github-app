#  SPDX-License-Identifier: BSD-2-Clause
#
#  check.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'jwt'
require 'octokit'
require 'json'
require 'netrc'
require 'yaml'
require 'logger'

require_relative '../helpers/configuration'

module Github
  class Check
    attr_reader :app, :check_suite

    def initialize(check_suite)
      @check_suite = check_suite
      @config = GitHubApp::Configuration.instance.config
      @logger = GithubLogger.instance.create('github_check_api.log', Logger::INFO)

      authenticate_app
    end

    def pull_request_info(pr_id, repo)
      @app.pull_request(repo, pr_id).to_h
    end

    def fetch_pull_request_commits(pr_id, repo, page)
      @app.pull_request_commits(
        repo,
        pr_id,
        per_page: 100,
        page: page
      )
    end

    def add_comment(pr_id, comment, repo)
      @app.add_comment(
        repo,
        pr_id,
        comment
      ).to_h
    end

    def comment_reaction_thumb_up(repo, comment_id)
      @app.create_issue_comment_reaction(repo, comment_id, '+1')
    end

    def comment_reaction_thumb_down(repo, comment_id)
      @app.create_issue_comment_reaction(repo, comment_id, '-1')
    end

    def check_runs_for_ref(repo, sha, status: 'queued')
      @app.check_runs_for_ref(repo, sha, status: status)
    end

    def create(name)
      @app.create_check_run(
        @check_suite.pull_request.repository,
        name,
        @check_suite.commit_sha_ref
      )
    end

    def queued(check_ref, output = {})
      basic_status(check_ref, 'queued', output)
    end

    def in_progress(check_ref, output = {})
      basic_status(check_ref, 'in_progress', output)
    end

    def cancelled(check_ref, output = {})
      completed(check_ref, 'completed', 'cancelled', output)
    end

    def success(check_ref, output = {})
      completed(check_ref, 'completed', 'success', output)
    end

    def failure(check_ref, output = {})
      completed(check_ref, 'completed', 'failure', output)
    end

    def skipped(check_ref, output = {})
      completed(check_ref, 'completed', 'skipped', output)
    end

    def get_check_run(check_ref)
      @app.check_run(@check_suite.pull_request.repository, check_ref).to_h
    end

    def installation_id
      @authenticate_app.find_app_installations.first['id'].to_i
    end

    def signature
      @config.dig('auth_signature', 'password')
    end

    def fetch_username(username)
      @app.user(username)
    rescue StandardError
      false
    end

    private

    def basic_status(check_ref, status, output)
      opts = {
        status: status
      }

      opts[:output] = output unless output.empty?

      resp =
        @app.update_check_run(
          @check_suite.pull_request.repository,
          check_ref.to_i,
          opts
        ).to_h

      @logger.info("basic_status: #{check_ref}, status: #{status} -> resp: #{resp}")

      resp
    end

    # PS: Conclusion and status are the same name from GitHub Check doc.
    # https://docs.github.com/en/rest/checks/runs?apiVersion=2022-11-28#update-a-check-run
    def completed(check_ref, status, conclusion, output)
      return if check_ref.nil?

      retry_count = 0

      begin
        opts = {
          status: status,
          conclusion: conclusion

        }

        opts[:output] = output unless output.empty?

        send_update(check_ref, opts, conclusion)
      rescue Octokit::NotFound, RuntimeError
        retry_count += 1

        sleep retry_count * 5

        retry if retry_count <= 3

        @logger.error "#{check_ref} not found at GitHub"

        {}
      end
    end

    def authenticate_app
      @config['github_apps'].each do |app|
        payload = generate_payload(app)

        rsa = OpenSSL::PKey::RSA.new(File.read(app['cert']))

        jwt = JWT.encode(payload, rsa, 'RS256')

        authenticate(jwt)

        break unless @app.nil?
      end

      raise 'Github Authentication Failed' if @app.nil?
    end

    def generate_payload(app)
      { iat: Time.now.to_i, exp: Time.now.to_i + (10 * 60) - 30, iss: app['login'] }
    end

    def authenticate(jwt)
      @authenticate_app = Octokit::Client.new(bearer_token: jwt)

      return if installation_id.zero?

      token =
        @authenticate_app
        .create_app_installation_access_token(installation_id)[:token]

      @app = Octokit::Client.new(bearer_token: token)
    end

    def send_update(check_ref, opts, conclusion)
      resp =
        @app.update_check_run(
          @check_suite.pull_request.repository,
          check_ref,
          opts
        ).to_h

      raise 'GitHub failed to update status' if resp[:conclusion] != conclusion

      @logger.info("completed: #{check_ref}, conclusion: #{conclusion} -> resp: #{resp}")

      resp
    end
  end
end
