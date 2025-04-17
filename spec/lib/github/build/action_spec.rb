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
  let(:action) { described_class.new(check_suite, fake_github_check, jobs) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:check_suite) { create(:check_suite) }
  let(:stage) { create(:stage, check_suite: check_suite) }
  let(:jobs) do
    [
      {
        name: ci_job.name,
        job_ref: ci_job.job_ref,
        stage: stage.configuration.bamboo_stage_name
      }
    ]
  end

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
    allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})
    allow(BambooCi::Result).to receive(:fetch).and_return({})

    allow(TimeoutExecution).to receive_message_chain(:delay, :timeout).and_return(true)

    stage
  end

  context 'when previous check suite has old tests' do
    let(:ci_job) { create(:ci_job, stage: stage, check_suite: check_suite) }
    let(:old_test) { create(:ci_job, stage: stage, check_suite: check_suite) }
    let(:skip_info) do
      {
        check_runs: [
          {
            app: {
              name: 'NetDEF CI Hook'
            },
            name: old_test.name,
            id: 1
          }
        ]
      }
    end

    before do
      old_test
      allow(Stage).to receive(:create).and_return(stage)
      allow(stage).to receive(:persisted?).and_return(false)
      allow(fake_github_check).to receive(:check_runs_for_ref).and_return(skip_info)
    end

    it 'must create a stage' do
      action.create_summary(rerun: false)
      expect(check_suite.reload.stages.size).to eq(1)
    end
  end

  context 'when previous check suite has old tests - but wrong app' do
    let(:ci_job) { create(:ci_job, stage: stage, check_suite: check_suite) }
    let(:old_test) { create(:ci_job, stage: stage, check_suite: check_suite) }
    let(:skip_info) do
      {
        check_runs: [
          {
            app: {
              name: 'NetDEF CI'
            },
            name: old_test.name,
            id: 1
          }
        ]
      }
    end

    before do
      old_test
      allow(Stage).to receive(:create).and_return(stage)
      allow(stage).to receive(:persisted?).and_return(false)
      allow(fake_github_check).to receive(:check_runs_for_ref).and_return(skip_info)
    end

    it 'must create a stage' do
      action.create_summary(rerun: false)
      expect(check_suite.reload.stages.size).to eq(1)
    end
  end

  context 'when could not create stage' do
    let(:ci_job) { create(:ci_job, stage: stage, check_suite: check_suite) }

    before do
      allow(Stage).to receive(:create).and_return(stage)
      allow(stage).to receive(:persisted?).and_return(false)
    end

    it 'must create a stage' do
      action.create_summary(rerun: false)
      expect(check_suite.reload.stages.size).to eq(1)
    end
  end

  context 'when stage can not retry' do
    let(:ci_job) { create(:ci_job, :failure, stage: stage, check_suite: check_suite) }

    before do
      ci_job
      stage.update(status: :failure)
      stage.configuration.update(can_retry: false)
    end

    it 'must not change' do
      action.create_summary(rerun: true)
      expect(stage.reload.status).to eq('failure')
      expect(ci_job.reload.status).to eq('failure')
    end
  end

  context 'when stage start_in_progress' do
    let(:ci_job) { create(:ci_job, :failure, stage: stage, check_suite: check_suite) }

    before do
      ci_job
      stage.update(status: :failure)
      stage.configuration.update(start_in_progress: true)
    end

    it 'must not change' do
      action.create_summary(rerun: true)
      expect(stage.reload.status).to eq('in_progress')
    end
  end

  context 'when stage does not exists' do
    let(:ci_job) { create(:ci_job) }
    let(:check_suite_new) { create(:check_suite) }

    before do
      stage.configuration.update(start_in_progress: true)
      described_class.new(check_suite_new, fake_github_check, jobs).create_summary(rerun: false)
    end

    it 'must not change' do
      expect(check_suite_new.reload.stages.order(id: :asc).first.status).to eq('queued')
    end
  end

  context 'when stage is the Final' do
    let(:ci_job) { create(:ci_job, name: 'Final') }
    let(:check_suite_new) { create(:check_suite) }

    before do
      stage.configuration.update(start_in_progress: true)
      described_class.new(check_suite_new, fake_github_check, [ci_job]).create_summary(rerun: false)
    end

    it 'must not change' do
      expect { described_class.new(check_suite_new, fake_github_check, [ci_job]).create_summary(rerun: false) }
        .not_to raise_error
    end
  end
end
