#  SPDX-License-Identifier: BSD-2-Clause
#
#  sinatra_payload_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class Dummy
  include Sinatra::Payload

  attr_accessor :payload_raw

  def request; end

  def env; end

  def halt(_, _opt = nil)
    false
  end
end

describe Sinatra::Payload do
  let(:dummy) { Dummy.new }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
  end

  describe '.authenticate_request' do
    let(:fake_client) { Octokit::Client.new }

    before do
      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
    end

    context 'when receives an empty payload' do
      let(:payload) { {} }

      it 'must returns nil' do
        expect(dummy.authenticate_request).to be_falsey
      end
    end

    context 'when receives HTTP_X_HUB_SIGNATURE_256 with valid password' do
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:config) { GitHubApp::Configuration.instance.config }
      let(:id) { 123 }
      let(:env) { { 'HTTP_X_HUB_SIGNATURE_256' => "sha256=#{signature}" } }

      let(:signature) do
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                config.dig('auth_signature', 'password'),
                                payload.to_json)
      end

      let(:payload) do
        {
          'status' => 'in_progress'
        }
      end

      before do
        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => id }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => id })

        allow(dummy).to receive(:request).and_return(dummy)
        allow(dummy).to receive(:env).and_return(env)

        dummy.payload_raw = payload.to_json
      end

      it 'must authenticate' do
        expect(dummy.authenticate_request).to be_truthy
      end
    end

    context 'when receives HTTP_X_HUB_SIGNATURE_256 with invalid password' do
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:id) { 123 }
      let(:env) { { 'HTTP_X_HUB_SIGNATURE_256' => "sha256=#{signature}" } }

      let(:signature) do
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                'ABCD',
                                payload.to_json)
      end

      let(:payload) do
        {
          'status' => 'in_progress'
        }
      end

      before do
        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => id }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => id })

        allow(dummy).to receive(:request).and_return(dummy)
        allow(dummy).to receive(:env).and_return(env)

        dummy.payload_raw = payload.to_json
      end

      it 'must authenticate' do
        expect(dummy.authenticate_request).to be_falsey
      end
    end

    context 'when receives blank HTTP_X_HUB_SIGNATURE_256' do
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:config) { GithubApp.configuration }
      let(:id) { 123 }
      let(:env) { { 'HTTP_X_HUB_SIGNATURE_256' => '' } }

      let(:signature) do
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                config.dig('auth_signature', 'password'),
                                payload.to_json)
      end

      let(:payload) do
        {
          'status' => 'in_progress'
        }
      end

      before do
        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => id }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => id })

        allow(dummy).to receive(:request).and_return(dummy)
        allow(dummy).to receive(:env).and_return(env)

        dummy.payload_raw = payload.to_json
      end

      it 'must not authenticate' do
        expect(dummy.authenticate_request).to be_falsey
      end
    end

    context 'when does not receive any authentication method' do
      let(:fake_github_check) { Github::Check.new(nil) }

      let(:payload) do
        {
          'status' => 'in_progress'
        }
      end

      before do
        allow(Github::Check).to receive(:new).and_return(fake_github_check)

        allow(dummy).to receive(:request).and_return(dummy)
        allow(dummy).to receive(:env).and_return({})

        dummy.payload_raw = payload.to_json
      end

      it 'must not authenticate' do
        expect(dummy.authenticate_request).to be_falsey
      end
    end
  end

  describe '.authenticate_metrics' do
    let(:metrics_config) { { 'username' => 'admin', 'password' => 'secret' } }
    let(:valid_auth) { "Basic #{Base64.strict_encode64('admin:secret')}" }

    before do
      base_config = GitHubApp::Configuration.instance.config
      allow(GitHubApp::Configuration.instance).to receive(:config)
        .and_return(base_config.merge('metrics_auth' => metrics_config))
      allow(dummy).to receive(:request).and_return(dummy)
      allow(dummy).to receive(:env).and_return(env)
    end

    context 'when HTTP_AUTHORIZATION header is absent' do
      let(:env) { {} }

      it 'returns 401' do
        expect(dummy.authenticate_metrics).to be_falsey
      end
    end

    context "when HTTP_AUTHORIZATION header does not start with 'Basic '" do
      let(:env) { { 'HTTP_AUTHORIZATION' => 'Bearer sometoken' } }

      it 'returns 401' do
        expect(dummy.authenticate_metrics).to be_falsey
      end
    end

    context 'when metrics_auth config is not set' do
      let(:env) { { 'HTTP_AUTHORIZATION' => valid_auth } }
      let(:metrics_config) { nil }

      it 'returns 401' do
        expect(dummy.authenticate_metrics).to be_falsey
      end
    end

    context 'when credentials are valid' do
      let(:env) { { 'HTTP_AUTHORIZATION' => valid_auth } }

      it 'returns true' do
        expect(dummy.authenticate_metrics).to be_truthy
      end
    end

    context 'when username is wrong' do
      let(:env) { { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('wronguser:secret')}" } }

      it 'returns 401' do
        expect(dummy.authenticate_metrics).to be_falsey
      end
    end

    context 'when password is wrong' do
      let(:env) { { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:wrongpass')}" } }

      it 'returns 401' do
        expect(dummy.authenticate_metrics).to be_falsey
      end
    end
  end
end
