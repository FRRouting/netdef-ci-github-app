# frozen_string_literal: true

require 'jwt'
require 'octokit'
require 'json'
require 'netrc'

module Github
  class Check
    attr_reader :installation_id

    def initialize(payload)
      @payload = payload
      @netrc = Netrc.read
      authenticate_app
      auth_installation
    end

    def create(name)
      @app.create_check_run(
        @payload['pull_request']['base']['repo']['full_name'],
        name,
        @payload['pull_request']['head']['sha'],
        accept: 'application/vnd.github+json'
      )
    end

    def update(id, status)
      @app.update_check_run(
        @payload['pull_request']['base']['repo']['full_name'],
        id,
        status: status,
        accept: 'application/vnd.github+json'
      )
    end

    def success(name)
      completed(name, 'completed', 'success')
    end

    def failed(name)
      completed(name, 'completed', 'failure')
    end

    def app_id
      @netrc['GITHUB-APP'].login
    end

    private

    def completed(name, status, conclusion)
      @app.update_check_run(
        @payload['pull_request']['base']['repo']['full_name'],
        name,
        status: status,
        conclusion: conclusion,
        accept: 'application/vnd.github+json'
      )
    end

    def authenticate_app
      payload = { iat: Time.now.to_i, exp: Time.now.to_i + (10 * 60), iss: @netrc['GITHUB-APP'].login.to_i }

      rsa = OpenSSL::PKey::RSA.new(File.read('private_key.pem'))

      jwt = JWT.encode(payload, rsa, 'RS256')

      @authenticate_app = Octokit::Client.new(bearer_token: jwt)
      @authenticate_app.login
    end

    def auth_installation
      @installation_id = @payload['installation']['id']
      token = @authenticate_app.create_app_installation_access_token(@installation_id)[:token]
      @app = Octokit::Client.new(bearer_token: token)
    end
  end
end
