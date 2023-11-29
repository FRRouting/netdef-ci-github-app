#  SPDX-License-Identifier: BSD-2-Clause
#
#  download_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::Download do
  context 'when download a file' do
    let(:service) { described_class.build_log(url) }
    let(:plan_key) { 1 }
    let(:url) { 'https://127.0.0.1/rest/api/latest/queue/' }

    before do
      stub_request(:get, url)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return([{ status: 200, body: '', headers: {} }, { status: 200, body: 'ok', headers: {} }])
    end

    it 'must returns success' do
      expect(service).to eq('ok')
    end
  end

  context 'when download a file, but never return success' do
    let(:service) { described_class.build_log(url) }
    let(:plan_key) { 1 }
    let(:url) { 'https://127.0.0.1/rest/api/latest/queue/' }

    before do
      stub_request(:get, url)
        .with(
          headers: {
            'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return({ status: 200, body: '', headers: {} })
    end

    it 'must returns an empty string' do
      expect(service).to eq('')
    end
  end
end
