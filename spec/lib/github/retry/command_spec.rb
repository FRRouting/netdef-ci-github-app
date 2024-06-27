#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Retry::Command do
  let(:github_retry) { described_class.new(payload) }
  let(:fake_unavailable) { Github::Build::UnavailableJobs.new(nil) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Github::Build::UnavailableJobs).to receive(:new).and_return(fake_unavailable)
  end

  context 'when receives an empty payload' do
    let(:payload) { {} }

    it 'must returns error' do
      expect(github_retry.start).to eq([422, 'Payload can not be blank'])
    end
  end

  describe 'Validates different Ci Job status' do
    let(:payload) do
      {
        'check_run' => {
          'id' => stage.check_ref
        }
      }
    end

    context 'when Ci Job is queued' do
      let(:stage) { create(:stage) }
      let(:ci_job) { create(:ci_job, stage: stage) }

      it 'must returns not modified' do
        expect(github_retry.start).to eq([406, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is in_progress' do
      let(:stage) { create(:stage, :in_progress) }
      let(:ci_job) { create(:ci_job, status: 'in_progress') }

      it 'must returns not modified' do
        expect(github_retry.start).to eq([406, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is failure' do
      let(:configuration) { create(:stage_configuration) }
      let(:check_suite) { create(:check_suite) }
      let(:ci_job) { create(:ci_job, check_suite: check_suite, status: 'failure', stage: ci_job_build_stage) }
      let(:fake_client) { Octokit::Client.new }
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:stage) { create(:stage, check_suite: check_suite, status: 'failure', configuration: configuration) }
      let(:ci_job_checkout_code) do
        create(:ci_job, check_suite: check_suite, status: 'failure', stage: stage)
      end
      let(:payload) do
        {
          'check_run' => {
            'id' => ci_job_build_stage.check_ref
          },
          'sender' => {
            'login' => 'test',
            'id' => 1,
            'type' => 'user'
          }
        }
      end
      let(:ci_job_build_stage) do
        create(:stage,
               check_suite: check_suite, status: 'failure',
               configuration: configuration, name: configuration.github_check_run_name)
      end

      before do
        ci_job
        ci_job_checkout_code

        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(ci_job.check_suite)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:fetch_username).and_return({})

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::Retry).to receive(:restart)

        allow(BambooCi::RunningPlan).to receive(:fetch).and_return([])

        ci_job_checkout_code
        ci_job_build_stage
      end

      it 'must returns success' do
        expect(github_retry.start).to eq([200, 'Retrying failure jobs'])
        expect(ci_job.reload.status).to eq('queued')
      end

      it 'must create audit retry' do
        github_retry.start
        expect(AuditRetry.count).to eq(1)
        expect(AuditRetry.first.github_username).to eq('test')
      end

      it 'must still have its previous status' do
        expect(ci_job_checkout_code.reload.status).to eq('failure')
      end
    end

    context 'when Ci Job is failure and checkout code is stage' do
      let(:check_suite) { create(:check_suite) }
      let(:stage) { create(:stage, :failure, check_suite: check_suite) }
      let(:ci_job) { create(:ci_job, check_suite: check_suite, status: 'failure', stage: stage) }
      let(:fake_client) { Octokit::Client.new }
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:ci_job_build_stage) { create(:stage, :failure, :can_not_retry, check_suite: check_suite, status: 'failure') }
      let(:ci_job_checkout_code) do
        create(:ci_job, check_suite: check_suite, status: 'failure', stage: ci_job_build_stage)
      end

      let(:payload) do
        {
          'check_run' => {
            'id' => ci_job_build_stage.check_ref
          }
        }
      end
      let(:output) do
        {
          output:
            {
              title: 'Failure',
              summary: 'Failure'
            }
        }
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(stage.check_suite)
        allow(fake_github_check).to receive(:get_check_run).and_return(output)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:failure)
        allow(fake_github_check).to receive(:fetch_username).and_return({})

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::Retry).to receive(:restart)

        allow(SlackBot.instance).to receive(:invalid_rerun_group)

        ci_job
        ci_job_checkout_code
      end

      it 'must returns success' do
        expect(github_retry.start).to eq([200, 'Retrying failure jobs'])
        expect(ci_job.reload.status).to eq('queued')
      end

      it 'must still have its previous status' do
        expect(ci_job_checkout_code.reload.status).to eq('failure')
      end
    end

    context 'when Ci Job is failure but has job running' do
      let(:payload) do
        {
          'check_run' => {
            'id' => stage1.check_ref
          }
        }
      end
      let(:payload2) do
        {
          'check_run' => {
            'id' => stage2.check_ref
          }
        }
      end
      let(:pr_number) { check_suite.pull_request.github_pr_id }
      let(:check_suite) { create(:check_suite) }
      let(:stage1) { create(:stage, :failure, check_suite: check_suite) }
      let(:stage2) { create(:stage, :in_progress, check_suite: check_suite) }
      let(:ci_job1) { create(:ci_job, check_suite: check_suite, status: 'failure', stage: stage1) }
      let(:ci_job2) { create(:ci_job, check_suite: check_suite, status: 'failure', stage: stage2) }
      let(:ci_job_running) { create(:ci_job, check_suite: check_suite, status: 'in_progress', stage: stage2) }
      let(:fake_config) { GitHubApp::Configuration.instance }
      let(:fake_client) { Octokit::Client.new }
      let(:fake_github_check) { Github::Check.new(nil) }
      let(:url) { 'https://test.free' }
      let(:output1) do
        {
          output:
            {
              title: '',
              summary: 'Cannot rerun because there are still tests running'
            }
        }
      end
      let(:output2) do
        {
          output:
            {
              title: '',
              summary: ''
            }
        }
      end
      let(:reason) do
        "PR <https://github.com/Unit/Test/pull/#{pr_number}|##{pr_number}> " \
          'tried to perform a partial rerun, but there were still tests running.'
      end

      before do
        stub_request(:post, "#{url}/github/comment").to_return(status: 200, body: '', headers: {})
        stub_request(:post, "#{url}/github/user").to_return(status: 200, body: '', headers: {})

        allow(GitHubApp::Configuration).to receive(:instance).and_return(fake_config)
        allow(fake_config).to receive(:config).and_return({ 'slack_bot_url' => url, 'github_apps' => [{}] })

        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:failure)
        allow(fake_github_check).to receive(:get_check_run).with(stage1.check_ref).and_return(output1)
        allow(fake_github_check).to receive(:get_check_run).with(stage2.check_ref).and_return(output2)

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::Retry).to receive(:restart)

        create(:pull_request_subscription, pull_request: check_suite.pull_request, target: pr_number)

        ci_job1
        ci_job2
        ci_job_running
      end

      it 'must not allow running again and set job as failure' do
        expect(github_retry.start).to eq([406, reason])
        expect(ci_job1.reload.status).to eq('failure')
        expect(ci_job2.reload.status).to eq('failure')
      end

      it 'must not change tests status' do
        described_class.new(payload2).start
        expect(ci_job1.reload.status).to eq('failure')
        expect(ci_job2.reload.status).to eq('failure')
      end
    end
  end
end
