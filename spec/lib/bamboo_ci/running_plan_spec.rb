# frozen_string_literal: true

describe BambooCi::RunningPlan do
  let(:service) { described_class.fetch(plan_key) }

  context 'when request a running plan' do
    let(:plan_key) { 1 }
    let(:status) { 200 }
    let(:url) { "https://127.0.0.1/rest/api/latest/result/#{plan_key}?expand=stages.stage.results" }

    let(:body) do
      {
        'stages' => {
          'stage' => [
            {
              'results' => {
                'result' => [
                  { 'key' => 1, 'plan' => { 'shortName' => 'unit-test' } }
                ]
              }
            }
          ]
        }
      }
    end

    before do
      stub_request(:get, url)
        .with(
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: body.to_json, headers: {})
    end

    it 'must returns success' do
      expect(service).to eq([{ job_ref: 1, name: 'unit-test' }])
    end
  end

  context 'when request a running plan but failed' do
    let(:plan_key) { 1 }
    let(:status) { 200 }
    let(:url) { "https://127.0.0.1/rest/api/latest/result/#{plan_key}?expand=stages.stage.results" }

    before do
      stub_request(:get, url)
        .with(
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: '', headers: {})
    end

    it 'must returns success' do
      expect(service).to eq([])
    end
  end
end
