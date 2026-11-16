#  SPDX-License-Identifier: BSD-2-Clause
#
#  api_service_account_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::Api, 'with a Bamboo service account' do
  let(:client) do
    Class.new do
      include BambooCi::Api

      def initialize
        @logger_manager = [Logger.new(File::NULL)]
      end
    end.new
  end

  let(:account) { BambooCi::ServiceAccount.instance }
  let(:token_url) { 'https://127.0.0.1/rest/oauth2/latest/token' }
  let(:url) { 'https://127.0.0.1/rest/api/latest/search/jobs/PLAN' }

  before do
    account.reset
    allow(GitHubApp::Configuration.instance)
      .to receive_messages(bamboo_service_account: %w[client-id client-secret], bamboo_oauth_scope: 'READ')
    allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })
  end

  after { account.reset }

  context 'when the token is accepted' do
    before do
      stub_request(:post, token_url).to_return(status: 200, body: { access_token: 'tok-1' }.to_json)
      stub_request(:get, url)
        .with(headers: { 'Authorization' => 'Bearer tok-1' })
        .to_return(status: 200, body: { 'size' => 1 }.to_json)
    end

    it 'sends the Bearer token instead of the netrc credentials' do
      expect(client.fetch_executions('PLAN')).to eq({ 'size' => 1 })
    end

    it 'posts with the Bearer token' do
      stub_request(:post, 'https://127.0.0.1/rest/api/latest/result/KEY/comment')
        .with(headers: { 'Authorization' => 'Bearer tok-1' })
        .to_return(status: 204)

      expect(client.add_comment_to_ci('KEY', 'comment').code.to_i).to eq(204)
    end
  end

  context 'when Bamboo refuses a cached token' do
    before do
      stub_request(:post, token_url)
        .to_return({ status: 200, body: { access_token: 'tok-1' }.to_json },
                   { status: 200, body: { access_token: 'tok-2' }.to_json })
      account.token_for(URI(url))

      stub_request(:get, url).with(headers: { 'Authorization' => 'Bearer tok-1' }).to_return(status: 401)
      stub_request(:get, url)
        .with(headers: { 'Authorization' => 'Bearer tok-2' })
        .to_return(status: 200, body: { 'size' => 2 }.to_json)
    end

    it 'gets a new token and sends the request once more' do
      expect(client.fetch_executions('PLAN')).to eq({ 'size' => 2 })
    end
  end

  context 'when Bamboo refuses a cached token and no new one can be obtained' do
    before do
      stub_request(:post, token_url)
        .to_return({ status: 200, body: { access_token: 'tok-1' }.to_json }, { status: 401, body: '' })
      account.token_for(URI(url))

      stub_request(:delete, url).to_return(status: 401)
    end

    it 'returns the refusal' do
      expect(client.delete_request(URI(url)).code.to_i).to eq(401)
    end
  end

  context 'when Bamboo refuses a fresh token' do
    before do
      stub_request(:post, token_url).to_return(status: 200, body: { access_token: 'tok-1' }.to_json)
      stub_request(:delete, url)
        .with(headers: { 'Authorization' => 'Bearer tok-1' })
        .to_return(status: 403, body: { message: 'missing scope' }.to_json)
    end

    it 'does not retry and returns the refusal' do
      expect(client.delete_request(URI(url)).code.to_i).to eq(403)
      expect(a_request(:delete, url)).to have_been_made.once
    end
  end

  context 'when no token can be obtained' do
    before do
      stub_request(:post, token_url).to_return(status: 401, body: '')
      stub_request(:delete, url).to_return(status: 401)
    end

    it 'sends the request without credentials' do
      client.delete_request(URI(url))

      expect(a_request(:delete, url).with { |req| !req.headers.key?('Authorization') }).to have_been_made.once
    end
  end
end
