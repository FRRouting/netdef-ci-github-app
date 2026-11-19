#  SPDX-License-Identifier: BSD-2-Clause
#
#  git_hub_app_request_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe GitHubApp::Request do
  let(:dummy_class) { Class.new { include GitHubApp::Request } }
  let(:instance) { dummy_class.new }

  describe '#get_request_with_status' do
    before { allow(instance).to receive(:fetch_user_pass).and_return(%w[user passwd]) }

    def answer(body, code)
      allow(instance).to receive(:create_http)
        .and_return(double('http', request: double('response', body: body, code: code)))
    end

    it 'adds the HTTP status to a JSON object' do
      answer('{"name": "NetDEF"}', '404')

      expect(instance.get_request_with_status(URI('http://localhost/test')))
        .to eq({ 'name' => 'NetDEF', 'http-status' => 404 })
    end

    it 'returns any other JSON value as is' do
      answer('[1, 2]', '200')

      expect(instance.get_request_with_status(URI('http://localhost/test'))).to eq([1, 2])
    end
  end

  describe '#get_request' do
    context 'when request json object' do
      it 'must return a hash' do
        allow(instance).to receive(:fetch_user_pass).and_return(%w[user passwd])
        allow(instance).to receive(:create_http).and_return(double('http',
                                                                   request: double('response',
                                                                                   body: '{"name": "NetDEF"}')))

        result = instance.get_request(URI('http://localhost/test'), json: true)
        expect(result).to eq({ 'name' => 'NetDEF' })
      end
    end

    context 'when request string object' do
      it 'must return a string' do
        allow(instance).to receive(:fetch_user_pass).and_return(%w[user passwd])
        allow(instance).to receive(:create_http).and_return(double('http',
                                                                   request: double('response',
                                                                                   body: '{"name": "NetDEF"}')))

        result = instance.get_request(URI('http://localhost/test'), json: false)
        expect(result).not_to eq({ 'name' => 'NetDEF' })
      end
    end
  end

  describe 'when sending the request raises' do
    let(:uri) { URI('http://localhost/test') }
    # Like the includers (e.g. BambooCi::PlanRun), logger returns the Array of loggers.
    let(:dummy_class) do
      Class.new do
        include GitHubApp::Request

        def logger(_severity, _message)
          []
        end
      end
    end

    before do
      allow(instance).to receive(:fetch_user_pass).and_return(%w[user passwd])
      allow(instance).to receive(:create_http).and_raise(Errno::ECONNREFUSED)
    end

    it 'post_request returns nil instead of the logger result' do
      expect(instance.post_request(uri)).to be_nil
    end

    it 'put_request returns nil instead of the logger result' do
      expect(instance.put_request(uri)).to be_nil
    end
  end
end
