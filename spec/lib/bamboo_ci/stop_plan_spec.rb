#  SPDX-License-Identifier: BSD-2-Clause
#
#  stop_plan_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::StopPlan do
  context '#stop' do
    let(:service) { described_class.stop(job_key) }
    let(:job_key) { 1 }
    let(:url) { "https://127.0.0.1/rest/api/latest/queue/#{job_key}" }

    before do
      allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })

      stub_request(:delete, url)
        .with(
          headers: {
            'Accept' => %w[*/*],
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

  context '#build' do
    let(:service) { described_class.build(job_key) }
    let(:job_key) { 1 }
    let(:url) { "https://127.0.0.1/build/admin/stopPlan.action?planResultKey=#{job_key}" }
    let(:response) { { 'status' => 'ok' } }

    before do
      allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })

      stub_request(:get, url)
        .with(
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: response.to_json, headers: {})
    end

    it 'must returns success' do
      expect(service).to eq(response)
    end
  end

  context '#comment' do
    let(:check_suite) { create(:check_suite) }
    let(:new_check_suite) { create(:check_suite) }
    let(:service) { described_class.comment(check_suite, new_check_suite) }
    let(:url) { "https://127.0.0.1/rest/api/latest/result/#{check_suite.bamboo_ci_ref}/comment" }
    let(:response) { { 'status' => 'ok' } }

    before do
      allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })

      stub_request(:post, url).to_return(status: 200, body: response.to_json, headers: {})
    end

    it 'must returns success' do
      expect(service.code.to_i).to eq(200)
    end
  end
end
