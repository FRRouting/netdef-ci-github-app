#  SPDX-License-Identifier: BSD-2-Clause
#
#  action_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::Action do
  let(:action) { described_class.new(check_suite, fake_github_check) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:check_suite) { create(:check_suite) }

  before do
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:create).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:failure).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:in_progress).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:skipped).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:success).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:cancelled).and_return(ci_job.check_suite)
    allow(fake_github_check).to receive(:queued).and_return(ci_job.check_suite)
    allow(BambooCi::Result).to receive(:fetch).and_return({})
  end

  context 'when could not create stage' do
    let(:ci_job) { create(:ci_job) }

    before do
      allow(CiJob).to receive(:create).and_return(ci_job)
      allow(ci_job).to receive(:persisted?).and_return(false)
    end

    it 'must not create a stage' do
      action.create_stage('Build', false)
      expect(check_suite.ci_jobs.stages.size).to eq(0)
    end
  end

  context 'when create stage in progess' do
    let(:ci_job) { create(:ci_job) }

    it 'must not create a stage' do
      action.create_stage('Build', true)
      expect(check_suite.ci_jobs.stages.size).to eq(1)
      expect(check_suite.ci_jobs.stages.first.status).to eq('in_progress')
    end
  end
end
