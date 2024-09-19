#  SPDX-License-Identifier: BSD-2-Clause
#
#  unavailable_jobs_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::UnavailableJobs do
  let(:unavailable_jobs) { described_class.new(check_suite) }
  let(:check_suite) { create(:check_suite) }
  let(:stage) { create(:stage, check_suite: check_suite) }
  let(:jobs) { create_list(:ci_job, 2, check_suite: check_suite, stage: stage) }
  let(:fake_client) { Octokit::Client.new }

  before do
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
    allow(fake_client).to receive(:update_check_run).and_return({ conclusion: 'skipped' })
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
  end

  context 'when has a new suite' do
    let(:unavailable_job) { jobs.last }
    let(:available_job) { jobs.first }
    let(:new_check_suite) { create(:check_suite) }

    before do
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ job_ref: unavailable_job.job_ref }])
    end

    it 'must change check suite' do
      unavailable_jobs.update(new_check_suite: new_check_suite)
      expect(new_check_suite.reload.ci_jobs.size).to eq(1)
      expect(check_suite.reload.ci_jobs.size).to eq(1)
    end
  end

  context 'when has not a new suite' do
    let(:unavailable_job) { jobs.last }
    let(:available_job) { jobs.first }
    let(:new_check_suite) { create(:check_suite) }

    before do
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ job_ref: unavailable_job.job_ref }])
    end

    it 'must change check suite' do
      unavailable_jobs.update
      expect(new_check_suite.reload.ci_jobs.size).to eq(0)
      expect(check_suite.reload.ci_jobs.size).to eq(2)
    end
  end

  context 'when check suite is null' do
    let(:check_suite) { nil }
    let(:unavailable_job) { jobs.last }
    let(:available_job) { jobs.first }
    let(:new_check_suite) { create(:check_suite) }

    before do
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ job_ref: unavailable_job.job_ref }])
    end

    it 'must return nil' do
      expect(unavailable_jobs.update).to be_nil
    end
  end
end
