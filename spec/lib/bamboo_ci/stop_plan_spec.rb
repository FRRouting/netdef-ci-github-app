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

  context '#build with a service account' do
    let(:account) { BambooCi::ServiceAccount.instance }
    let(:bamboo_ci_ref) { 'PLAN-12' }
    let(:result_url) { "https://127.0.0.1/rest/api/latest/result/#{bamboo_ci_ref}?expand=stages.stage.results" }
    let(:job_state) { 'InProgress' }
    let(:running_plan) do
      { 'stages' => { 'stage' => [{ 'results' => { 'result' => [{ 'key' => 'PLAN-JOB1-12', 'stage' => 'Build',
                                                                  'lifeCycleState' => job_state,
                                                                  'plan' => { 'shortName' => 'Job 1' } }] } }] } }
    end

    before do
      account.reset
      allow(GitHubApp::Configuration.instance)
        .to receive_messages(bamboo_service_account: %w[client-id client-secret], bamboo_oauth_scope: 'READ')

      stub_request(:post, 'https://127.0.0.1/rest/oauth2/latest/token')
        .to_return(status: 200, body: { access_token: 'tok-1' }.to_json)
      stub_request(:get, result_url).to_return(status: 200, body: running_plan.to_json)
      stub_request(:delete, %r{https://127.0.0.1/rest/api/latest/queue/}).to_return(status: 204)
    end

    after { account.reset }

    it 'stops the execution and its jobs through the REST API' do
      expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(204)
      expect(a_request(:delete, "https://127.0.0.1/rest/api/latest/queue/#{bamboo_ci_ref}")).to have_been_made
      expect(a_request(:delete, 'https://127.0.0.1/rest/api/latest/queue/PLAN-JOB1-12')).to have_been_made
      expect(a_request(:get, /stopPlan.action/)).not_to have_been_made
    end

    it 'does nothing without an execution' do
      expect(described_class.build(nil)).to be_nil
    end

    context 'when Bamboo refuses to stop a running job' do
      let(:app_logger) { instance_double(Logger, add: true) }

      before do
        described_class.instance_variable_set(:@app_logger, app_logger)
        stub_request(:delete, 'https://127.0.0.1/rest/api/latest/queue/PLAN-JOB1-12')
          .to_return(status: 403, body: { message: 'Missing WRITE scope' }.to_json)
      end

      after { described_class.instance_variable_set(:@app_logger, nil) }

      it 'returns the refused job response instead of the execution one' do
        expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(403)
      end

      it 'logs the refusal' do
        described_class.build(bamboo_ci_ref)

        expect(app_logger)
          .to have_received(:add).with(Logger::ERROR, /refused to stop PLAN-JOB1-12: HTTP 403 Missing WRITE scope/)
      end
    end

    context 'when the job already finished' do
      let(:job_state) { 'Finished' }

      before do
        stub_request(:delete, 'https://127.0.0.1/rest/api/latest/queue/PLAN-JOB1-12').to_return(status: 404)
      end

      it 'reports the execution as stopped' do
        expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(204)
      end
    end

    context 'when a running job is no longer in the queue' do
      let(:job_result_url) { 'https://127.0.0.1/rest/api/latest/result/PLAN-JOB1-12?expand=' }

      before do
        stub_request(:delete, 'https://127.0.0.1/rest/api/latest/queue/PLAN-JOB1-12').to_return(status: 404)
      end

      it 'does not confirm the stop while Bamboo still runs the job' do
        stub_request(:get, job_result_url).to_return(status: 200, body: { lifeCycleState: 'InProgress' }.to_json)

        expect(described_class.build(bamboo_ci_ref)).to be_nil
        expect(described_class.stop_execution(bamboo_ci_ref)).to be(false)
      end

      it 'confirms the stop once Bamboo reports the job as finished' do
        stub_request(:get, job_result_url).to_return(status: 200, body: { lifeCycleState: 'Finished' }.to_json)

        expect(described_class.stop_execution(bamboo_ci_ref)).to be(true)
      end
    end

    context 'when Bamboo no longer knows the build' do
      before do
        stub_request(:delete, "https://127.0.0.1/rest/api/latest/queue/#{bamboo_ci_ref}").to_return(status: 404)
        stub_request(:get, result_url).to_return(status: 404, body: { message: 'not found' }.to_json)
      end

      it 'takes the execution as stopped' do
        expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(404)
        expect(described_class.stop_execution(bamboo_ci_ref)).to be(true)
      end
    end

    context 'when Bamboo does not list the jobs of a build it still knows' do
      before do
        stub_request(:delete, "https://127.0.0.1/rest/api/latest/queue/#{bamboo_ci_ref}").to_return(status: 404)
        stub_request(:get, result_url).to_return(status: 500, body: { message: 'error' }.to_json)
      end

      it 'does not confirm the stop' do
        expect(described_class.build(bamboo_ci_ref)).to be_nil
      end
    end

    context 'when the execution DELETE fails but every job is stopped' do
      before do
        stub_request(:delete, "https://127.0.0.1/rest/api/latest/queue/#{bamboo_ci_ref}").to_raise(Errno::ECONNRESET)
      end

      it 'confirms the stop' do
        expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(204)
        expect(described_class.stop_execution(bamboo_ci_ref)).to be(true)
      end
    end

    context 'when Bamboo lists a stage without results' do
      let(:running_plan) { { 'stages' => { 'stage' => [{ 'results' => {} }] } } }

      it 'stops the execution without raising' do
        expect(described_class.build(bamboo_ci_ref).code.to_i).to eq(204)
      end
    end

    context 'when stopping raises unexpectedly' do
      let(:app_logger) { instance_double(Logger, add: true) }

      before do
        described_class.instance_variable_set(:@app_logger, app_logger)
        allow(described_class).to receive(:stop_by_rest).and_raise(NoMethodError, 'odd answer')
      end

      after { described_class.instance_variable_set(:@app_logger, nil) }

      it 'does not confirm the stop and logs the error' do
        expect(described_class.build(bamboo_ci_ref)).to be_nil
        expect(described_class.stop_execution(bamboo_ci_ref)).to be(false)
        expect(app_logger).to have_received(:add).with(Logger::ERROR, /Stop of PLAN-12 failed: NoMethodError/).twice
      end
    end

    context 'when a stop request raises' do
      let(:app_logger) { instance_double(Logger, add: true) }

      before do
        described_class.instance_variable_set(:@app_logger, app_logger)
        stub_request(:delete, 'https://127.0.0.1/rest/api/latest/queue/PLAN-JOB1-12').to_raise(Errno::ECONNRESET)
      end

      after { described_class.instance_variable_set(:@app_logger, nil) }

      it 'counts the job as refused and logs the error' do
        expect(described_class.build(bamboo_ci_ref)).to be_nil
        expect(app_logger)
          .to have_received(:add).with(Logger::ERROR, /stop request for PLAN-JOB1-12 failed: Errno::ECONNRESET/)
      end
    end

    context 'when the execution DELETE gets no response' do
      let(:app_logger) { instance_double(Logger, add: true) }

      before do
        described_class.instance_variable_set(:@app_logger, app_logger)
        allow(described_class).to receive(:delete_request).and_return(nil)
      end

      after { described_class.instance_variable_set(:@app_logger, nil) }

      it 'logs the failure and returns nil' do
        expect(described_class.build(bamboo_ci_ref)).to be_nil
        expect(app_logger).to have_received(:add).with(Logger::ERROR, /refused to stop PLAN-12: HTTP /)
      end
    end
  end

  describe '.stop_execution' do
    let(:account) { BambooCi::ServiceAccount.instance }

    before { allow(described_class).to receive(:build).and_return(response) }

    context 'without a service account' do
      let(:response) { nil }

      before { allow(account).to receive(:configured?).and_return(false) }

      it 'takes the execution as stopped' do
        expect(described_class.stop_execution('PLAN-12')).to be(true)
      end
    end

    context 'with a service account' do
      before { allow(account).to receive(:configured?).and_return(true) }

      context 'when Bamboo accepts the stop' do
        let(:response) { Net::HTTPNoContent.new('1.1', '204', 'No Content') }

        it { expect(described_class.stop_execution('PLAN-12')).to be(true) }
      end

      context 'when Bamboo refuses the stop' do
        let(:response) { Net::HTTPForbidden.new('1.1', '403', 'Forbidden') }

        it { expect(described_class.stop_execution('PLAN-12')).to be(false) }
      end

      context 'when there is no execution' do
        let(:response) { nil }

        it { expect(described_class.stop_execution(nil)).to be(true) }
      end
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
