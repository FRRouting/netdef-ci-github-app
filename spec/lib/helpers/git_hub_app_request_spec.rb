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
end
