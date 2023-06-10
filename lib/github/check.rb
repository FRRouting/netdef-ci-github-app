# frozen_string_literal: true

require 'jwt'
require 'octokit'
require 'json'
require 'netrc'
require 'yaml'

module Github
  class Check
    attr_reader :installation_id

    def initialize(payload)
      @payload = payload
      @config = YAML.load_file('config.yml')
      authenticate_app
      auth_installation
    end

    def create(name)
      @app.create_check_run(
        fetch_repo_name,
        name,
        fetch_sha,
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
      completed(id, 'completed', 'cancelled')
    end

    def success(name, _output: '')
      completed(name, 'completed', 'success')
    end

    def failure(name, _output: '')
      completed(name, 'completed', 'failure')
    end

    def app_id
      @config.dig('github_app', 'login')
    end

    private

    def basic_status(id, status)
      @app.update_check_run(
        fetch_repo_name,
        id.to_i,
        status: status,
        accept: 'application/vnd.github+json'
      )
    end

    # PS: Conclusion and status are the same name from GitHub Check doc.
    # https://docs.github.com/en/rest/checks/runs?apiVersion=2022-11-28#update-a-check-run
    def completed(name, status, conclusion)
      @app.update_check_run(
        fetch_repo_name,
        name,
        status: status,
        conclusion: conclusion,
        accept: 'application/vnd.github+json'
      )
    end

    def authenticate_app
      payload = { iat: Time.now.to_i, exp: Time.now.to_i + (10 * 60), iss: app_id }

      puts payload

      rsa = OpenSSL::PKey::RSA.new(File.read('private_key.pem'))

      jwt = JWT.encode(payload, rsa, 'RS256')

      @authenticate_app = Octokit::Client.new(bearer_token: jwt)
      @authenticate_app.login
    end

    def auth_installation
      @installation_id = @payload.dig('installation', 'id')
      token = @authenticate_app.create_app_installation_access_token(@installation_id)[:token]
      @app = Octokit::Client.new(bearer_token: token)
    end

    def fetch_repo_name
      @payload.dig('pull_request', 'base', 'repo', 'full_name') ||
        @payload.dig('repository', 'full_name')
    end

    def fetch_sha
      @payload.dig('pull_request', 'head', 'sha') ||
        @payload.dig('check_run', 'check_suite', 'head_sha')
    end
  end
end
