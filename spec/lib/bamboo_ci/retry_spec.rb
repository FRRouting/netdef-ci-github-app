#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::Retry do
  before do
    allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })
  end

  context 'when call restart' do
    let(:service) { described_class.restart(plan_key) }
    let(:plan_key) { 1 }
    let(:url) { "https://127.0.0.1/rest/api/latest/queue/#{plan_key}?executeAllStages=true" }

    before do
      stub_request(:put, url)
        .with(
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: 'ok', headers: {})
    end

    it 'must returns success' do
      expect(service.code.to_i).to eq(200)
    end
  end

  context 'when call rerun' do
    let(:service) { described_class.rerun(plan_key) }
    let(:plan_key) { 1 }
    let(:url) { "https://127.0.0.1/rest/api/latest/queue/#{plan_key}?executeAllStages=true&orphanRemoval=true" }

    before do
      stub_request(:put, url)
        .with(
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: 'ok', headers: {})
    end

    it 'must returns success' do
      expect(service).to eq('ok')
    end
  end
end
