#  SPDX-License-Identifier: BSD-2-Clause
#
#  summary_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::Summary do
  let(:summary) { described_class.new(ci_job) }
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

  context 'when the build stage finished successfully' do
    let(:ci_job) { create(:ci_job, :build, :success, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::BUILD_STAGE)
      expect(build_stage.reload.status).to eq('success')
      expect(tests_stage.reload.status).to eq('in_progress')
    end
  end

  context 'when the build stage finished unsuccessfully' do
    let(:ci_job) { create(:ci_job, :build, :failure, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::BUILD_STAGE)
      expect(build_stage.reload.status).to eq('failure')
      expect(tests_stage.reload.status).to eq('cancelled')
    end
  end

  context 'when the build stage still running' do
    let(:ci_job) { create(:ci_job, :build, :success, check_suite: check_suite) }
    let(:ci_job_running) { create(:ci_job, :build, :in_progress, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      ci_job_running
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::BUILD_STAGE)
      expect(build_stage.reload.status).to eq('in_progress')
      expect(tests_stage.reload.status).to eq('queued')
    end
  end

  context 'when the tests stage finished successfully' do
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, status: :success, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::TESTS_STAGE)
      expect(build_stage.reload.status).to eq('success')
      expect(tests_stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage finished unsuccessfully' do
    let(:ci_job) { create(:ci_job, :test, :failure, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, status: :success, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::TESTS_STAGE)
      expect(build_stage.reload.status).to eq('success')
      expect(tests_stage.reload.status).to eq('failure')
    end
  end

  context 'when the tests stage still running' do
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite) }
    let(:ci_job_running) { create(:ci_job, :test, :in_progress, check_suite: check_suite) }
    let(:build_stage) { create(:ci_job, :build_stage, status: :success, check_suite: check_suite) }
    let(:tests_stage) { create(:ci_job, :tests_stage, check_suite: check_suite) }

    before do
      ci_job_running
      build_stage
      tests_stage
    end

    it 'must update stage' do
      summary.build_summary(Github::Build::Action::TESTS_STAGE)
      expect(build_stage.reload.status).to eq('success')
      expect(tests_stage.reload.status).to eq('in_progress')
    end
  end
end
