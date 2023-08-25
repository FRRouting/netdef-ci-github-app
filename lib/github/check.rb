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

module Github
  class Check
    attr_reader :app, :check_suite

    def initialize(check_suite)
      @check_suite = check_suite
      @config = GitHubApp::Configuration.instance.config
      @logger = Logger.new($stdout)

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
      )
    end

    def comment_reaction_thumb_up(repo, comment_id)
      @app.create_issue_comment_reaction(repo, comment_id, '+1')
    end

    def create(name)
      @app.create_check_run(
        @check_suite.pull_request.repository,
        name,
        @check_suite.commit_sha_ref,
        accept: 'application/vnd.github+json'
      )
    end

    def queued(id)
      basic_status(id, 'queued', {})
    end

    def in_progress(id, output = {})
      basic_status(id, 'in_progress', output)
    end

    def cancelled(id)
      completed(id, 'completed', 'cancelled', {})
    rescue Octokit::NotFound
      @logger.error "ID ##{id} not found at GitHub"
    end

    def success(name, output = {})
      completed(name, 'completed', 'success', output)
    rescue Octokit::NotFound
      @logger.error "ID ##{id} not found at GitHub"
    end

    def failure(name, output = {})
      completed(name, 'completed', 'failure', output)
    rescue Octokit::NotFound
      @logger.error "ID ##{id} not found at GitHub"
    end

    def skipped(name)
      completed(name, 'completed', 'skipped', {})
    rescue Octokit::NotFound
      @logger.error "ID ##{id} not found at GitHub"
    end

    def installation_id
      list = @authenticate_app.find_app_installations

      return 0 if list.first.is_a? Array and list.first&.last&.match? 'Missing'

      list.first['id']
    end

    def signature
      @config.dig('auth_signature', 'password')
    end

    private

    def basic_status(id, status, output)
      opts = {
        status: status,
        accept: 'application/vnd.github+json'
      }

      opts[:output] = output unless output.empty?

      @app.update_check_run(
        @check_suite.pull_request.repository,
        id.to_i,
        opts
      )
    end

    # PS: Conclusion and status are the same name from GitHub Check doc.
    # https://docs.github.com/en/rest/checks/runs?apiVersion=2022-11-28#update-a-check-run
    def completed(name, status, conclusion, output)
      opts = {
        status: status,
        conclusion: conclusion,
        accept: 'application/vnd.github+json'
      }

      opts[:output] = output unless output.empty?

      @logger.info @app.update_check_run(
        @check_suite.pull_request.repository,
        name,
        opts
      )
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

      token = @authenticate_app.create_app_installation_access_token(installation_id)[:token]
      @app = Octokit::Client.new(bearer_token: token)
    end
  end
end
