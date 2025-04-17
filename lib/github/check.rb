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
  # Class responsible for interacting with GitHub's Check API.
  #
  # This class provides methods to authenticate with GitHub, fetch pull request information,
  # manage check runs, and handle comments and reactions on pull requests.
  #
  # @attr_reader [Object] app the authenticated GitHub app client.
  # @attr_reader [Object] check_suite the check suite associated with the pull request.
  class Check
    attr_reader :app, :check_suite

    # Initializes a new Github::Check object.
    #
    # @param check_suite [Object] the check suite associated with the pull request.
    def initialize(check_suite)
      @check_suite = check_suite
      @config = GitHubApp::Configuration.instance.config
      @logger = GithubLogger.instance.create('github_check_api.log', Logger::INFO)

      authenticate_app
    end

    # Fetches information about a pull request.
    #
    # @param pr_id [Integer] the pull request ID.
    # @param repo [String] the repository name.
    # @return [Hash] the pull request information.
    def pull_request_info(pr_id, repo)
      @app.pull_request(repo, pr_id).to_h
    end

    # Fetches commits associated with a pull request.
    #
    # @param pr_id [Integer] the pull request ID.
    # @param repo [String] the repository name.
    # @param page [Integer] the page number for pagination.
    # @return [Array<Hash>] the list of commits.
    def fetch_pull_request_commits(pr_id, repo, page)
      @app.pull_request_commits(
        repo,
        pr_id,
        per_page: 100,
        page: page
      )
    end

    # Adds a comment to a pull request.
    #
    # @param pr_id [Integer] the pull request ID.
    # @param comment [String] the comment text.
    # @param repo [String] the repository name.
    # @return [Hash] the added comment information.
    def add_comment(pr_id, comment, repo)
      @app.add_comment(
        repo,
        pr_id,
        comment
      ).to_h
    end

    # Adds a thumbs-up reaction to a comment.
    #
    # @param repo [String] the repository name.
    # @param comment_id [Integer] the comment ID.
    def comment_reaction_thumb_up(repo, comment_id)
      @app.create_issue_comment_reaction(repo, comment_id, '+1')
    end

    # Adds a thumbs-down reaction to a comment.
    #
    # @param repo [String] the repository name.
    # @param comment_id [Integer] the comment ID.
    def comment_reaction_thumb_down(repo, comment_id)
      @app.create_issue_comment_reaction(repo, comment_id, '-1')
    end

    # Fetches check runs for a specific commit SHA.
    #
    # @param repo [String] the repository name.
    # @param sha [String] the commit SHA.
    # @param status [String] the status of the check runs to fetch.
    # @return [Array<Hash>] the list of check runs.
    def check_runs_for_ref(repo, sha, status: 'queued')
      @app.check_runs_for_ref(repo, sha, status: status)
    end

    # Creates a new check run.
    #
    # @param name [String] the name of the check run.
    # @return [Hash] the created check run information.
    def create(name)
      @app.create_check_run(
        @check_suite.pull_request.repository,
        name,
        @check_suite.commit_sha_ref
      )
    end

    # Updates the status of a check run to 'queued'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def queued(check_ref, output = {})
      basic_status(check_ref, 'queued', output)
    end

    # Updates the status of a check run to 'in_progress'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def in_progress(check_ref, output = {})
      basic_status(check_ref, 'in_progress', output)
    end

    # Updates the status of a check run to 'cancelled'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def cancelled(check_ref, output = {})
      completed(check_ref, 'completed', 'cancelled', output)
    end

    # Updates the status of a check run to 'success'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def success(check_ref, output = {})
      completed(check_ref, 'completed', 'success', output)
    end

    # Updates the status of a check run to 'failure'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def failure(check_ref, output = {})
      completed(check_ref, 'completed', 'failure', output)
    end

    # Updates the status of a check run to 'skipped'.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
    def skipped(check_ref, output = {})
      completed(check_ref, 'completed', 'skipped', output)
    end

    # Fetches a specific check run.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @return [Hash] the check run information.
    def get_check_run(check_ref)
      @app.check_run(@check_suite.pull_request.repository, check_ref).to_h
    end

    def installation_id
      @authenticate_app.find_app_installations.first['id'].to_i
    end

    def signature
      @config.dig('auth_signature', 'password')
    end

    # Fetches the username associated with a GitHub user.
    #
    # @param username [String] the GitHub username.
    # @return [Hash, false] the user information if found, otherwise false.
    def fetch_username(username)
      @app.user(username)
    rescue StandardError
      false
    end

    private

    # Updates the status of a check run.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param status [String] the status of the check run.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
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

    # Completes a check run with a specific conclusion.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param status [String] the status of the check run.
    # @param conclusion [String] the conclusion of the check run.
    # @param output [Hash] the output information for the check run.
    # @return [Hash] the updated check run information.
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

    # Authenticates the GitHub app.
    #
    # This method attempts to authenticate the GitHub app by repository. If the
    # authentication by repository fails or the check suite is nil, it falls back
    # to authenticating the default GitHub app.
    #
    # @raise [RuntimeError] if the GitHub authentication fails.
    def authenticate_app
      github_app_by_repo

      github_default_app if @check_suite.nil? or @app.nil?
    end

    # Authenticates the GitHub app by repository.
    #
    # This method finds the GitHub app configuration for the repository associated
    # with the check suite and creates a GitHub app client using that configuration.
    def github_app_by_repo
      app =
        @config['github_apps'].find do |entry|
          entry.key? 'repo' and entry['repo'] == @check_suite&.pull_request&.repository
        end

      @logger.info("github_app_by_repo: #{app.inspect}")

      create_app(app) unless app.nil?
    end

    def github_default_app
      @config['github_apps'].each do |app|
        create_app(app)

        break unless @app.nil?
      end

      raise 'Github Authentication Failed' if @app.nil?
    end

    # Creates a GitHub app client.
    #
    # @param app [Hash] the app configuration.
    def create_app(app)
      payload = generate_payload(app)

      rsa = OpenSSL::PKey::RSA.new(File.read(app['cert']))

      jwt = JWT.encode(payload, rsa, 'RS256')

      authenticate(jwt)
    end

    # Generates a payload for authentication.
    #
    # @param app [Hash] the app configuration.
    # @return [Hash] the generated payload.
    def generate_payload(app)
      { iat: Time.now.to_i, exp: Time.now.to_i + (10 * 60) - 30, iss: app['login'] }
    end

    # Authenticates the GitHub app with a JWT.
    #
    # @param jwt [String] the JWT token.
    def authenticate(jwt)
      @authenticate_app = Octokit::Client.new(bearer_token: jwt)

      return if installation_id.zero?

      token =
        @authenticate_app
        .create_app_installation_access_token(installation_id)[:token]

      @app = Octokit::Client.new(bearer_token: token)
    end

    # Sends an update to GitHub for a check run.
    #
    # @param check_ref [Integer] the check run reference ID.
    # @param opts [Hash] the options for the update.
    # @param conclusion [String] the conclusion of the check run.
    # @return [Hash] the updated check run information.
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
