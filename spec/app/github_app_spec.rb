# frozen_string_literal: true

describe 'GithubApp' do
  context 'when ping route is called' do
    it 'returns success' do
      get '/ping'

      expect(last_response.status).to eq 200
      expect(last_response.body).to eq('Pong')
    end
  end

  describe '#UpdateStatus' do
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

      let(:config) { Configuration.instance.config }

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

  describe '#Commands' do

  end
end
