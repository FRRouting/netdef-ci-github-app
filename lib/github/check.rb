# frozen_string_literal: true

require 'jwt'
require 'octokit'
require 'json'
require 'netrc'
require 'yaml'
require 'logger'

module Github
  class Check
    attr_reader :app

    def initialize(check_suite)
      @check_suite = check_suite
      @config = YAML.load_file('config.yml')
      @logger = Logger.new($stdout)

      authenticate_app
      auth_installation
    end

    def add_comment(pr_id, comment, repo)
      @app.add_comment(
        repo,
        pr_id,
        comment
      )
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
      basic_status(id, 'queued')
    end

    def in_progress(id)
      basic_status(id, 'in_progress')
    end

    def cancelled(id)
      completed(id, 'completed', 'cancelled', {})
    end

    def success(name, output = {})
      completed(name, 'completed', 'success', output)
    end

    def failure(name, output = {})
      completed(name, 'completed', 'failure', output)
    end

    def skipped(name)
      completed(name, 'completed', 'skipped', {})
    end

    def app_id
      @config.dig('github_app', 'login')
    end

    def installation_id
      list = @authenticate_app.find_app_installations
      list.first['id']
    end

    def signature
      @config.dig('auth_signature', 'password')
    end

    private

    def basic_status(id, status)
      @app.update_check_run(
        @check_suite.pull_request.repository,
        id.to_i,
        status: status,
        accept: 'application/vnd.github+json'
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
      payload = { iat: Time.now.to_i, exp: Time.now.to_i + (10 * 60), iss: app_id }

      rsa = OpenSSL::PKey::RSA.new(File.read(@config.dig('github_app', 'cert')))

      jwt = JWT.encode(payload, rsa, 'RS256')

      @authenticate_app = Octokit::Client.new(bearer_token: jwt)
      @authenticate_app.login
    end

    def auth_installation
      token = @authenticate_app.create_app_installation_access_token(installation_id)[:token]
      @app = Octokit::Client.new(bearer_token: token)
    end
  end
end
