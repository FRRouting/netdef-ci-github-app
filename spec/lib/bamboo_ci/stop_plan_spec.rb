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
  context 'when call stop' do
    let(:service) { described_class.stop(job_key) }
    let(:job_key) { 1 }
    let(:url) { "https://127.0.0.1/rest/api/latest/queue/#{job_key}" }

    before do
      stub_request(:delete, url)
        .with(
          headers: {
            'Accept' => %w[*/*],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
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
end
