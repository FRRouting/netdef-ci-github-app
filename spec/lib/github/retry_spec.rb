#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Retry do
  let(:github_retry) { described_class.new(payload) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
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
          'id' => ci_job.check_ref
        }
      }
    end

    context 'when Ci Job is queued' do
      let(:ci_job) { create(:ci_job) }

      it 'must returns not modified' do
        expect(github_retry.start).to eq([406, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is in_progress' do
      let(:ci_job) { create(:ci_job, status: 'in_progress') }

      it 'must returns not modified' do
        expect(github_retry.start).to eq([406, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is failure' do
      let(:check_suite) { create(:check_suite) }
      let(:ci_job) { create(:ci_job, check_suite: check_suite, status: 'failure') }
      let(:ci_job_success) { create(:ci_job, check_suite: check_suite, status: 'failure', name: 'Checkout Code') }
      let(:fake_client) { Octokit::Client.new }
      let(:fake_github_check) { Github::Check.new(nil) }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(ci_job.check_suite)
        allow(fake_github_check).to receive(:queued)

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::Retry).to receive(:restart)
      end

      it 'must returns success' do
        expect(github_retry.start).to eq([200, 'Retrying failure jobs'])
        expect(ci_job.reload.status).to eq('queued')
      end
    end

    context 'when Ci Job is failure but has job running' do
      let(:payload) do
        {
          'check_run' => {
            'id' => ci_job1.check_ref
          }
        }
      end
      let(:payload2) do
        {
          'check_run' => {
            'id' => ci_job2.check_ref
          }
        }
      end
      let(:check_suite) { create(:check_suite) }
      let(:ci_job1) { create(:ci_job, check_suite: check_suite, status: 'failure') }
      let(:ci_job2) { create(:ci_job, check_suite: check_suite, status: 'failure') }
      let(:ci_job_running) { create(:ci_job, check_suite: check_suite, status: 'in_progress') }
      let(:fake_client) { Octokit::Client.new }
      let(:fake_github_check) { Github::Check.new(nil) }
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


      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:failure)
        allow(fake_github_check).to receive(:get_check_run).with(ci_job1.check_ref).and_return(output1)
        allow(fake_github_check).to receive(:get_check_run).with(ci_job2.check_ref).and_return(output2)

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::Retry).to receive(:restart)

        ci_job1
        ci_job2
        ci_job_running
      end

      it 'must not allow running again and set job as failure' do
        expect(github_retry.start).to eq([406, 'Cannot rerun because there are still tests running'])
        expect(ci_job1.reload.status).to eq('failure')
        expect(ci_job2.reload.status).to eq('failure')
      end

      it do
        described_class.new(payload2).start
        expect(ci_job1.reload.status).to eq('failure')
        expect(ci_job2.reload.status).to eq('failure')
      end
    end
  end
end
