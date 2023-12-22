#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::Retry do
  let(:github_retry) { described_class.new(check_suite, fake_github_check) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:check_suite) { create(:check_suite) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:create).and_return(ci_job)
    allow(fake_github_check).to receive(:failure)
    allow(fake_github_check).to receive(:in_progress)
    allow(fake_github_check).to receive(:skipped)
    allow(fake_github_check).to receive(:success)
    allow(fake_github_check).to receive(:cancelled)
    allow(fake_github_check).to receive(:queued)
  end

  context 'when stage can not be retry' do
    let(:configuration) { create(:stage_configuration, can_retry: false) }
    let(:stage) { create(:stage, :failure, check_suite: check_suite, configuration: configuration) }
    let(:ci_job) { create(:ci_job, :failure, stage: stage, check_suite: check_suite) }

    before do
      stage
      ci_job

      github_retry.enqueued_stages
      github_retry.enqueued_failure_tests
    end

    it 'must continue as failure' do
      expect(stage.reload.status).to eq('failure')
      expect(ci_job.reload.status).to eq('failure')
    end
  end

  context 'when stage can be retry' do
    let(:configuration) { create(:stage_configuration, can_retry: true) }
    let(:ci_job) { create(:ci_job, :failure, stage: stage, check_suite: check_suite) }
    let(:stage) do
      create(:stage,
             check_suite: check_suite, configuration: configuration, name: configuration.github_check_run_name)
    end

    before do
      stage
      ci_job

      github_retry.enqueued_stages
      github_retry.enqueued_failure_tests
    end

    it 'must change to queued' do
      expect(stage.reload.status).to eq('queued')
      expect(ci_job.reload.status).to eq('queued')
    end
  end

  context 'when stage can be retry, but stage passed' do
    let(:configuration) { create(:stage_configuration, can_retry: true) }
    let(:ci_job) { create(:ci_job, :success, stage: stage, check_suite: check_suite) }
    let(:stage) do
      create(:stage,
             :success,
             check_suite: check_suite, configuration: configuration, name: configuration.github_check_run_name)
    end

    before do
      stage
      ci_job

      github_retry.enqueued_stages
      github_retry.enqueued_failure_tests
    end

    it 'must continue as success' do
      expect(stage.reload.status).to eq('success')
      expect(ci_job.reload.status).to eq('success')
    end
  end
end
