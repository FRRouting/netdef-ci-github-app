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

      context 'when receive HTTP_X_GITHUB_EVENT issue_comment' do
        let(:headers) do
          {
            'HTTP_ACCEPT' => 'application/json',
            'HTTP_SIGNATURE' => header,
            'HTTP_X_GITHUB_EVENT' => 'issue_comment'
          }
        end

        let(:payload) { { x: 1, 'action' => 'rerequested' } }

        before do
          allow(GitHubApp::Configuration.instance).to receive(:debug?).and_return(false)
        end

        it 'must returns error' do
          post '/', payload.to_json, headers

          expect(last_response.status).to eq 404
        end
      end
    end
  end
end
