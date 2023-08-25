#  SPDX-License-Identifier: BSD-2-Clause
#
#  sinatra_payload.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'sinatra/base'
require_relative '../github/check'
require_relative 'configuration'

module Sinatra
  module Payload
    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_request
      return halt 401 unless @payload_raw.present?

      sha = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                    GitHubApp::Configuration.instance.config.dig('auth_signature', 'password'),
                                    @payload_raw)

      signature = "sha256=#{sha}"
      http_signature = fetch_signature

      return halt 404, 'Signature not found' if http_signature.nil? or http_signature.empty?
      return halt 401, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, http_signature)

      @installation_client = Octokit::Client.new(bearer_token: signature)
    end

    private

    def fetch_signature
      request.env['HTTP_SIGNATURE'] || request.env['HTTP_X_HUB_SIGNATURE_256']
    end
  end

  helpers Payload
end
