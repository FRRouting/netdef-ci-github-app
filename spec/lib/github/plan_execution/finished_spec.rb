#  SPDX-License-Identifier: BSD-2-Clause
#
#  finished_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::PlanExecution::Finished do
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:pla_exec) { described_class.new(payload) }
  let(:check_suite) { create(:check_suite, :with_in_progress) }
  let(:url) do
    "https://127.0.0.1/rest/api/latest/result/#{check_suite.bamboo_ci_ref}?expand=stages.stage.results,artifacts"
  end

  let(:url_status) do
    "https://127.0.0.1/rest/api/latest/result/status/#{check_suite.bamboo_ci_ref}"
  end
  let(:build_status) { { 'currentStage' => 'Final', 'finished' => true } }
  let(:subscription) { create(:pull_request_subscription, target: check_suite.pull_request.github_pr_id) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })

    check_suite
    subscription

    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:create).and_return(check_suite)
    allow(fake_github_check).to receive(:failure).and_return(check_suite)
    allow(fake_github_check).to receive(:in_progress).and_return(check_suite)
    allow(fake_github_check).to receive(:skipped).and_return(check_suite)
    allow(fake_github_check).to receive(:success).and_return(check_suite)
    allow(fake_github_check).to receive(:cancelled).and_return(check_suite)
    allow(fake_github_check).to receive(:queued).and_return(check_suite)

    allow(SlackBot.instance).to receive(:notify_success)
    allow(SlackBot.instance).to receive(:notify_errors)
    allow(SlackBot.instance).to receive(:notify_cancelled)
    allow(SlackBot.instance).to receive(:execution_finished_notification)
    allow(SlackBot.instance).to receive(:stage_in_progress_notification)
    allow(SlackBot.instance).to receive(:stage_finished_notification)

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
      .to_return(status: status, body: body.to_json, headers: {})

    stub_request(:get, url_status)
      .with(
        headers: {
          'Accept' => %w[*/* application/json],
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
          'Host' => '127.0.0.1',
          'User-Agent' => 'Ruby'
        }
      )
      .to_return(status: status, body: build_status.to_json, headers: {})
  end

  describe 'Finishing execution' do
    context 'when receives a valid payload - Successful' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives a valid payload - Failed' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Failed' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives a valid payload - Unknown' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Unknown' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives a valid payload - DONE' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'DONE' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives a hanged check suite' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }
      let(:build_status) { { 'currentStage' => 'Build', 'progress' => { 'percentageCompleted' => 4.0 } } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives a stopped check suite' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }
      let(:build_status) { { 'currentStage' => 'Build', 'message' => 'Stopped by Github' } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives an invalid Job' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => 'test', 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }
      let(:build_status) { { 'currentStage' => 'Build', 'message' => 'Stopped by Github' } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Finished'])
      end
    end

    context 'when receives an invalid check suite' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => 0 } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([404, 'Check Suite not found'])
      end
    end

    context 'when receives an in_progress check suite' do
      let(:status) { 200 }
      let(:body) do
        {
          'stages' => {
            'stage' => [
              'results' => {
                'result' =>
                  check_suite.ci_jobs.map { |job| { 'buildResultKey' => job.job_ref, 'state' => 'Successful' } }
              }
            ]
          }
        }
      end
      let(:payload) { { 'bamboo_ref' => check_suite.bamboo_ci_ref } }
      let(:build_status) { { 'currentStage' => 'Build' } }

      it 'must returns error' do
        expect(pla_exec.finished).to eq([200, 'Still running'])
      end
    end
  end
end
