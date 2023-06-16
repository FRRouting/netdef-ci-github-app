# frozen_string_literal: true

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
          'bamboo_ref' => ci_job.job_ref
        }
      end

      it 'must returns not modified' do
        expect(update_status.update).to eq([304, 'Not Modified'])
      end
    end
  end
end