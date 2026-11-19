#  SPDX-License-Identifier: BSD-2-Clause
#
#  service_account_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::ServiceAccount do
  let(:account) { described_class.instance }
  let(:configuration) { GitHubApp::Configuration.instance }
  let(:uri) { URI('https://127.0.0.1/rest/api/latest/result/PLAN-1') }
  let(:token_url) { 'https://127.0.0.1/rest/oauth2/latest/token' }
  let(:credentials) { %w[client-id client-secret] }
  let(:scope) { 'READ TRIGGER WRITE' }

  before do
    account.reset
    allow(configuration).to receive_messages(bamboo_service_account: credentials, bamboo_oauth_scope: scope)
  end

  after { account.reset }

  describe '#configured?' do
    context 'when the client id and secret are set' do
      it 'returns true' do
        expect(account.configured?).to be true
      end
    end

    context 'when the service account is not set' do
      let(:credentials) { nil }

      it 'returns false' do
        expect(account.configured?).to be false
      end
    end
  end

  describe '#token_for' do
    context 'when Bamboo grants a token' do
      before do
        stub_request(:post, token_url)
          .with(body: { 'grant_type' => 'client_credentials', 'client_id' => 'client-id',
                        'client_secret' => 'client-secret', 'scope' => scope })
          .to_return(status: 200, body: { access_token: 'tok-1', expires_in: 3600, scope: 'READ' }.to_json)
      end

      it 'returns a fresh token' do
        expect(account.token_for(uri)).to eq(['tok-1', true])
      end

      it 'keeps the token for the next requests' do
        account.token_for(uri)

        expect(account.token_for(uri)).to eq(['tok-1', false])
        expect(a_request(:post, token_url)).to have_been_made.once
      end

      it 'records the granted scope' do
        account.token_for(uri)

        expect(account.granted_scope).to eq('READ')
      end
    end

    context 'when the token is about to expire' do
      before do
        stub_request(:post, token_url)
          .to_return(status: 200, body: { access_token: 'tok-1', expires_in: 30 }.to_json)
      end

      it 'fetches a new token on every request' do
        2.times { account.token_for(uri) }

        expect(a_request(:post, token_url)).to have_been_made.twice
      end
    end

    context 'when Bamboo grants every scope and omits the lifetime' do
      before do
        stub_request(:post, token_url)
          .to_return(status: 200, body: { access_token: 'tok-1', scope: scope }.to_json)
      end

      it 'uses the default lifetime' do
        account.token_for(uri)

        expect(account.token_for(uri)).to eq(['tok-1', false])
      end
    end

    context 'when the scope is empty' do
      let(:scope) { nil }

      before do
        stub_request(:post, token_url)
          .with(body: { 'grant_type' => 'client_credentials', 'client_id' => 'client-id',
                        'client_secret' => 'client-secret' })
          .to_return(status: 200, body: { access_token: 'tok-1' }.to_json)
      end

      it 'does not send a scope' do
        expect(account.token_for(uri)).to eq(['tok-1', true])
      end
    end

    context 'when Bamboo refuses the credentials' do
      before do
        stub_request(:post, token_url)
          .to_return(status: 401, body: { error: 'invalid_client', error_description: 'Bad credentials' }.to_json)
      end

      it 'returns no token and keeps the reason' do
        expect(account.token_for(uri)).to eq([nil, true])
        expect(account.last_error).to eq('HTTP 401 Bad credentials')
      end
    end

    context 'when Bamboo answers without a token' do
      before { stub_request(:post, token_url).to_return(status: 200, body: '[]') }

      it 'returns no token' do
        expect(account.token_for(uri)).to eq([nil, true])
        expect(account.last_error).to eq('HTTP 200 []')
      end
    end

    context 'when Bamboo answers with something that is not JSON' do
      before { stub_request(:post, token_url).to_return(status: 200, body: 'not json') }

      it 'returns no token' do
        expect(account.token_for(uri)).to eq([nil, true])
        expect(account.last_error).to eq('HTTP 200 not json')
      end
    end

    context 'when Bamboo cannot be reached' do
      before { stub_request(:post, token_url).to_raise(Errno::ECONNREFUSED) }

      it 'returns no token and keeps the reason' do
        expect(account.token_for(uri)).to eq([nil, true])
        expect(account.last_error).to start_with('Errno::ECONNREFUSED')
      end
    end
  end

  describe '#forget' do
    before do
      stub_request(:post, token_url)
        .to_return({ status: 200, body: { access_token: 'tok-1' }.to_json },
                   { status: 200, body: { access_token: 'tok-2' }.to_json })
      account.token_for(uri)
    end

    it 'drops the cached token' do
      account.forget('tok-1')

      expect(account.token_for(uri)).to eq(['tok-2', true])
    end

    it 'keeps a token that was already replaced' do
      account.forget('other')

      expect(account.token_for(uri)).to eq(['tok-1', false])
    end
  end

  describe '.summary' do
    def response(body)
      instance_double(Net::HTTPResponse, body: body)
    end

    it 'returns the JSON message' do
      expect(described_class.summary(response({ message: 'Forbidden' }.to_json))).to eq('Forbidden')
    end

    it 'returns the title of an HTML page' do
      html = '<html><head><title>HTTP Status 401 - Unauthorized</title></head></html>'

      expect(described_class.summary(response(html))).to eq('HTML page: HTTP Status 401 - Unauthorized')
    end

    it 'returns the start of any other body' do
      expect(described_class.summary(response("plain\n  text"))).to eq('plain text')
    end

    it 'describes an empty body' do
      expect(described_class.summary(response(nil))).to eq('(empty body)')
    end
  end
end
