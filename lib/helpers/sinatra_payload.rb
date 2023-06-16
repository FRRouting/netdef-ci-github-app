# frozen_string_literal: true

require 'sinatra/base'
require_relative '../github/check'

module Sinatra
  module Payload
    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      request.body.rewind
      @payload_raw = request.body&.read

      return @payload = {} if @payload_raw.nil? or @payload_raw.empty?

      @payload = JSON.parse @payload_raw
    rescue StandardError => e
      raise "Invalid JSON (#{e}): #{@payload_raw}"
    end

    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_request(payload)
      return if payload.empty?

      return auth_installation(payload) if !payload.dig('hook', 'app_id').nil? or payload.key? 'installation'
      return auth_signature if request.env.key? 'HTTP_X_HUB_SIGNATURE_256'

      halt 401
    end

    private

    def auth_installation(payload)
      github_check = Github::Check.new(nil)

      github_check.installation_id == payload.dig('hook', 'app_id') or
        github_check.installation_id == payload.dig('installation', 'id')
    end

    def auth_signature
      config

      sha = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                    @config.dig('auth_signature', 'password'),
                                    @payload_raw)

      signature = "sha256=#{sha}"
      http_signature = request.env['HTTP_SIGNATURE'] || request.env['HTTP_X_HUB_SIGNATURE_256']

      return halt 404, 'Signature not found' if http_signature.nil? or http_signature.empty?
      return halt 401, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, http_signature)

      @installation_client = Octokit::Client.new(bearer_token: signature)
    end

    def config
      @config ||= YAML.load_file('config.yml')
    end
  end

  helpers Payload
end
