# frozen_string_literal: true

require 'sinatra/base'

module Sinatra
  module Payload
    # Instantiate an Octokit client authenticated as a GitHub App.
    # GitHub App authentication requires that you construct a
    # JWT (https://jwt.io/introduction/) signed with the app's private key,
    # so GitHub can be sure that it came from the app an not altererd by
    # a malicious third party.
    def authenticate_app
      config

      payload = {
        # The time that this JWT was issued, _i.e._ now.
        iat: Time.now.to_i,

        # JWT expiration time (10 minute maximum)
        exp: Time.now.to_i + (10 * 60),

        # Your GitHub App's identifier number
        iss: @config.dig('auth_signature', 'password')
      }

      # Cryptographically sign the JWT.
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

      # Create the Octokit client, using the JWT as the auth token.
      @authenticate_app ||= Octokit::Client.new(bearer_token: jwt)
    end

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
    def authenticate_request
      return if @payload.empty?

      return auth_installation if @payload.key? 'installation'
      return auth_signature if request.env.key? 'HTTP_X_HUB_SIGNATURE_256'

      halt 401
    end

    private

    def auth_installation
      @installation_id = @payload['installation']['id']
      @installation_token = @authenticate_app.create_app_installation_access_token(@installation_id)[:token]
      @installation_client = Octokit::Client.new(bearer_token: @installation_token)
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
