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

  context 'when Bamboo is served under a context path' do
    before do
      allow(GitHubApp::Configuration.instance).to receive(:bamboo_api_url).and_return('https://host/bamboo')
      stub_request(:post, 'https://host/bamboo/rest/oauth2/latest/token')
        .to_return(status: 200, body: { access_token: 'tok-1' }.to_json)
      stub_request(:get, 'https://host/bamboo/rest/api/latest/search/jobs/PLAN')
        .with(headers: { 'Authorization' => 'Bearer tok-1' })
        .to_return(status: 200, body: { 'size' => 1 }.to_json)
    end

    it 'gets the token under that path and sends it to the REST endpoint' do
      expect(client.fetch_executions('PLAN')).to eq({ 'size' => 1 })
    end
  end

  context 'when the request is not a REST endpoint' do
    let(:log_url) { 'https://127.0.0.1/download/PLAN-JOB1/build_logs/PLAN-JOB1-12.log' }

    before do
      stub_request(:get, log_url)
        .with(headers: { 'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==' })
        .to_return(status: 200, body: "line 1\nline 2")
    end

    it 'uses the ~/.netrc credentials instead of the token' do
      expect(client.download(URI(log_url))).to eq("line 1\nline 2")
      expect(a_request(:post, token_url)).not_to have_been_made
    end

    context 'without ~/.netrc credentials' do
      before do
        allow(Netrc).to receive(:read).and_raise(Netrc::Error, 'missing')
        stub_request(:get, log_url).to_return(status: 401, body: '<html>login</html>')
      end

      it 'sends the request without credentials, so the caller sees the refusal' do
        expect(client.download(URI(log_url))).to eq('<html>login</html>')
        expect(a_request(:get, log_url).with { |req| req.headers['Authorization'].nil? }).to have_been_made
      end
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

      stub_request(:delete, url).with(headers: { 'Authorization' => 'Bearer tok-1' }).to_return(status: 401)
      stub_request(:delete, url).with(basic_auth: %w[user password]).to_return(status: 204)
    end

    it 'sends the request once more with the netrc credentials' do
      expect(client.delete_request(URI(url)).code.to_i).to eq(204)
    end

    context 'without netrc credentials' do
      before { allow(Netrc).to receive(:read).and_return({}) }

      it 'returns the refusal' do
        expect(client.delete_request(URI(url)).code.to_i).to eq(401)
      end
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

    it 'falls back to the netrc credentials' do
      stub_request(:delete, url).with(basic_auth: %w[user password]).to_return(status: 204)

      expect(client.delete_request(URI(url)).code.to_i).to eq(204)
    end

    context 'without netrc credentials' do
      before { allow(Netrc).to receive(:read).and_return({}) }

      it 'sends the request without credentials' do
        client.delete_request(URI(url))

        expect(a_request(:delete, url).with { |req| !req.headers.key?('Authorization') }).to have_been_made.once
      end
    end

    context 'when the netrc file cannot be read' do
      before { allow(Netrc).to receive(:read).and_raise(Netrc::Error, 'Permission bits for ~/.netrc should be 0600') }

      it 'sends the request without credentials' do
        client.delete_request(URI(url))

        expect(a_request(:delete, url).with { |req| !req.headers.key?('Authorization') }).to have_been_made.once
      end
    end
  end
end
