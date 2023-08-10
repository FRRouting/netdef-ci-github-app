# frozen_string_literal: true

require 'sinatra/base'
require_relative '../github/check'

module Sinatra
  module Payload
    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_request
      return halt 401 unless @payload_raw.present?

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

    private

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
      @config ||= GithubApp.configuration
    end
  end

  helpers Payload
end
