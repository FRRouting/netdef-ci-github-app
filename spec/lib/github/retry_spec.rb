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
        expect(github_retry.start).to eq([304, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is in_progress' do
      let(:ci_job) { create(:ci_job, status: 'in_progress') }

      it 'must returns not modified' do
        expect(github_retry.start).to eq([304, 'Already enqueued this execution'])
      end
    end

    context 'when Ci Job is failure' do
      let(:ci_job) { create(:ci_job, status: 'failure') }
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
  end
end
