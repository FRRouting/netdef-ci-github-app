#  SPDX-License-Identifier: BSD-2-Clause
#
#  update_status_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::UpdateStatus do
  let(:update_status) { described_class.new(payload) }

  describe 'Validates different Ci Job status' do
    let(:payload) do
      {
        'status' => status,
        'bamboo_ref' => ci_job.job_ref
      }
    end

    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }

    before do
      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(fake_github_check).to receive(:create).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:failure).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:in_progress).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:skipped).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:success).and_return(ci_job.check_suite)
    end

    context 'when Ci Job Checkout Code update from queued -> failure' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Code') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).to eq('skipped') }
      end
    end

    context 'when Ci Job Checkout Code update from queued -> in_progress' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Code') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'in_progress' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
      end
    end

    context 'when Ci Job AMD Build update from in_progress -> failure' do
      let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).to eq('skipped') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> failure' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> failure + topotest_failures' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:status) { 'failure' }
      let(:payload) do
        {
          'status' => status,
          'bamboo_ref' => ci_job.job_ref,
          'failures' => [
            failure_info
          ]
        }
      end

      let(:failure) { TopotestFailure.find_by(ci_job: ci_job) }
      let(:failure_info) do
        {
          'suite' => 'test_ospf_sr_te_topo1',
          'case' => 'test_ospf_sr_te_topo1',
          'message' => "E   AssertionError: rt1 don't has entry 1111 but is was expected\n    assert False",
          'execution_time' => 30
        }
      end

      before do
        ci_job
        update_status.update
      end

      it 'must creates a topotest_failure' do
        expect(failure.to_h).to eq(failure_info)
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> success' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'success' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> invalid' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'success' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end
  end

  describe 'Checking invalid commands' do
    context 'when receives an empty payload' do
      let(:payload) { {} }

      it 'must returns error' do
        expect(update_status.update).to eq([404, 'CI JOB not found'])
      end
    end

    context 'when receives an invalid CI Job' do
      let(:payload) do
        {
          'status' => 'invalid',
          'bamboo_ref' => 12_345
        }
      end

      it 'must returns error' do
        expect(update_status.update).to eq([404, 'CI JOB not found'])
      end
    end

    context 'when a test sends an invalid status' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'queued') }
      let(:payload) do
        {
          'status' => 'failure',
          'bamboo_ref' => ci_job.job_ref
        }
      end

      it 'must returns not modified' do
        expect(update_status.update).to eq([304, 'Not Modified'])
      end
    end

    context 'when building image sends an invalid status' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Codde', status: 'in_progress') }
      let(:payload) do
        {
          'status' => 'queued',
          'bamboo_ref' => ci_job.job_ref,
          'output' => {
            'title' => 'Title',
            'summary' => 'Summary'
          }
        }
      end

      it 'must returns not modified' do
        expect(update_status.update).to eq([304, 'Not Modified'])
      end
    end
  end
end
