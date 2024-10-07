#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_app_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe 'GithubApp' do
  context 'when ping route is called' do
    it 'returns success' do
      get '/ping'

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq('Pong')
    end
  end

  describe '#UpdateStatus' do
    before do
      allow(File).to receive(:read).and_return('')
      allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    end

    context 'when signature does not send' do
      it 'must returns error' do
        post '/update/status', {}.to_json, { 'HTTP_ACCEPT' => 'application/json' }

        expect(last_response.status).to eq 404
        expect(last_response.body).to eq('Signature not found')
      end
    end

    context 'when signature does not match' do
      it 'must returns error' do
        post '/update/status', {}.to_json, { 'HTTP_ACCEPT' => 'application/json', 'HTTP_SIGNATURE' => '1234' }

        expect(last_response.status).to eq 401
        expect(last_response.body).to eq("Signatures didn't match!")
      end
    end

    context 'when sending a valid request' do
      let(:payload) do
        {}
      end
      let(:config) { GitHubApp::Configuration.instance.config }

      let(:signature) do
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                                config.dig('auth_signature', 'password'),
                                payload.to_s)
      end

      let(:header) { "sha256=#{signature}" }
      let(:fake) { Github::UpdateStatus.new(payload) }

      before do
        allow(Github::UpdateStatus).to receive(:new).with(payload).and_return(fake)
        allow(fake).to receive(:update).and_return([200, 'Success'])
      end

      it 'must returns success' do
        post '/update/status', payload.to_json, { 'HTTP_ACCEPT' => 'application/json', 'HTTP_SIGNATURE' => header }

        expect(last_response.status).to eq 200
        expect(last_response.body).to eq('Success')
      end
    end
  end

  describe 'GitHub commands' do
    let(:config) { GitHubApp::Configuration.instance.config }

    let(:signature) do
      OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'),
                              config.dig('auth_signature', 'password'),
                              payload.to_json)
    end

    let(:header) { "sha256=#{signature}" }

    before do
      allow(File).to receive(:read).and_return('')
      allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    end

    context 'when receive HTTP_X_GITHUB_EVENT ping' do
      let(:headers) do
        {
          'HTTP_ACCEPT' => 'application/json',
          'HTTP_SIGNATURE' => header,
          'HTTP_X_GITHUB_EVENT' => 'ping'
        }
      end

      let(:payload) { {} }

      it 'must returns pong' do
        post '/', payload.to_json, headers

        expect(last_response.status).to eq 200
        expect(last_response.body).to eq('PONG!')
      end
    end

    context 'when receive HTTP_X_GITHUB_EVENT pull_request' do
      let(:headers) do
        {
          'HTTP_ACCEPT' => 'application/json',
          'HTTP_SIGNATURE' => header,
          'HTTP_X_GITHUB_EVENT' => 'pull_request'
        }
      end

      let(:payload) { { 'x' => 1 } }

      it 'must returns error' do
        post '/', payload.to_json, headers

        expect(last_response.status).to eq 405
      end

      context 'when receive HTTP_X_GITHUB_EVENT check_run' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'check_run'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested' } }

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT check_run with invalid action' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'check_run'
          }
        end

        let(:payload) { { x: 1, 'action' => 'potato' } }

        it 'must returns success' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 200
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT installation' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'installation'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested' } }

        it 'must returns success' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 202
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT potato' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'potato'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested' } }

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 401
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT issue_comment - rerun' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'issue_comment'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested', 'comment' => { 'body' => 'ci:rerun' } } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT issue_comment - retry' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'issue_comment'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested', 'comment' => { 'body' => 'ci:retry' } } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT issue_comment - potato' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'issue_comment'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested', 'comment' => { 'body' => 'just a potato' } } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns success' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 200
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT issue_comment - comment null' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'issue_comment'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested', 'comment' => nil } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT check_suite with empty payload' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'check_suite'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested', 'comment' => nil } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end

      context 'when receive HTTP_X_GITHUB_EVENT check_suite with invalid command' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'check_suite'
          }
        end

        let(:payload) { { x: 1, 'action' => 'potato' } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns success' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 200
        end
      end
    end
  end

  describe 'Slack commands' do
    let(:config) { GitHubApp::Configuration.instance.config }
    let(:account) { 'admin' }
    let(:password) { 'admin' }
    let(:auth) { "Basic #{["#{account}:#{password}"].pack('m0')}" }

    before do
      allow(Netrc).to receive(:read).and_return({ 'slack_bot.netdef.org' => [account, password] })
    end

    context 'when create a subscription' do
      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => auth
        }
      end

      let(:payload) do
        {
          'rule' => 'notify',
          'target' => 1,
          'notification' => 'all',
          'slack_user_id' => 'ABC'
        }
      end

      it 'must create a subscription' do
        post '/slack', payload.to_json, headers

        expect(last_response.status).to eq 200
      end
    end

    context 'when create a subscription but send wrong auth' do
      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => ''
        }
      end

      let(:payload) do
        {
          'rule' => 'notify',
          'target' => 1,
          'notification' => 'all',
          'slack_user_id' => 'ABC'
        }
      end

      it 'must create a subscription' do
        post '/slack', payload.to_json, headers

        expect(last_response.status).to eq 401
      end
    end

    context 'when fetch settings' do
      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => auth,
          'HTTP_ACCEPT' => 'application/json'
        }
      end

      let(:payload) do
        {
          'slack_user_id' => 'ABC'
        }
      end

      it 'must create a subscription' do
        post '/slack/settings', payload.to_json, headers

        expect(last_response.status).to eq 200
      end
    end

    context 'when fetch running PRs' do
      let(:ci_job) { create(:ci_job, :in_progress) }

      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => auth
        }
      end

      let(:payload) do
        {
          'event' => 'running',
          'github_user' => ci_job.check_suite.pull_request.author,
          'slack_user_id' => 'ABC'
        }
      end

      before do
        create(:ci_job, :in_progress)
      end

      it 'must return a table' do
        post '/slack', payload.to_json, headers

        expect(last_response.status).to eq 200
      end
    end

    context 'when fetch running PRs, but does not have any PR' do
      let(:ci_job) { create(:ci_job, :failure) }

      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => auth
        }
      end

      let(:payload) do
        {
          'event' => 'running',
          'github_user' => ci_job.check_suite.pull_request.author,
          'slack_user_id' => 'ABC'
        }
      end

      before do
        create(:ci_job, :in_progress)
        ci_job.stage.update(status: :failure)
        FileUtils.rm_rf File.expand_path('./logs')
      end

      it 'must return a table' do
        post '/slack', payload.to_json, headers

        expect(last_response.status).to eq 200
        expect(last_response.body).to eq 'No running PR'
      end
    end

    context 'when fetch settings but using wrong auth' do
      let(:headers) do
        {
          'HTTP_AUTHORIZATION' => ''
        }
      end

      let(:payload) do
        {
          'slack_user_id' => 'ABC'
        }
      end

      it 'must create a subscription' do
        post '/slack/settings', payload.to_json, headers

        expect(last_response.status).to eq 401
      end
    end
  end
end
