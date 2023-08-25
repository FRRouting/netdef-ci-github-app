# frozen_string_literal: true

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
end
