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
  let(:position1) { BambooStageTranslation.find_by_position(1) }
  let(:position2) { BambooStageTranslation.find_by_position(2) }
  let(:parent_stage1) { create(:parent_stage, check_suite: check_suite, name: position1.github_check_run_name) }
  let(:parent_stage2) { create(:parent_stage, check_suite: check_suite, name: position2.github_check_run_name) }

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
    let(:ci_job2) { create(:ci_job, :test, :in_progress, check_suite: check_suite) }

    before do
      ci_job
      ci_job2
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.parent_stage.reload.status).to eq('success')
      expect(ci_job2.parent_stage.reload.status).to eq('in_progress')
    end
  end

  context 'when the build stage finished unsuccessfully' do
    let(:ci_job) { create(:ci_job, :build, :failure, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, :test, status: :queued, check_suite: check_suite) }

    before do
      ci_job
      ci_job2
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.parent_stage.reload.status).to eq('failure')
      expect(ci_job2.parent_stage.reload.status).to eq('cancelled')
    end
  end

  context 'when the build stage still running' do
    let(:parent_stage) { create(:parent_stage, :build, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, parent_stage: parent_stage, check_suite: check_suite) }
    let(:ci_job_running) { create(:ci_job, :in_progress, parent_stage: parent_stage, check_suite: check_suite) }

    before do
      ci_job_running
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.parent_stage.reload.status).to eq('in_progress')
      expect(ci_job_running.parent_stage.reload.status).to eq('in_progress')
    end
  end

  context 'when the tests stage finished successfully' do
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite) }
    let(:ci_job1) { create(:ci_job, :build, :success, check_suite: check_suite) }

    before do
      ci_job
      ci_job1

      ci_job.update(parent_stage: parent_stage2)
      ci_job1.update(parent_stage: parent_stage1)

      described_class.new(ci_job).build_summary
    end

    it 'must update stage' do
      expect(ci_job.parent_stage.reload.status).to eq('success')
      expect(ci_job1.parent_stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage finished unsuccessfully' do
    let(:ci_job1) { create(:ci_job, :build, :success, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :test, :failure, check_suite: check_suite) }

    before do
      ci_job1
      ci_job

      ci_job.update(parent_stage: parent_stage2)
      ci_job1.update(parent_stage: parent_stage1)
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job1.parent_stage.reload.status).to eq('success')
      expect(ci_job.parent_stage.reload.status).to eq('failure')
    end
  end

  context 'when the tests stage still running' do
    let(:parent_stage) { create(:parent_stage, :test, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite, parent_stage: parent_stage) }
    let(:ci_job_running) { create(:ci_job, :test, :in_progress, check_suite: check_suite, parent_stage: parent_stage) }

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.parent_stage.reload.status).to eq('success')
      expect(ci_job_running.parent_stage.reload.status).to eq('success')
    end
  end

  context 'when parent_stage is nil' do
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite) }
    let(:fake_translation) { create(:bamboo_stage_translation) }
    let(:parent_stage) { create(:parent_stage, name: fake_translation.bamboo_stage_name, check_suite: check_suite) }
    let(:ci_jobs) do
      [
        { name: ci_job.name, job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
        { name: 'CHECKOUT', job_ref: 'CHECKOUT-1', stage: fake_translation.bamboo_stage_name }
      ]
    end

    before do
      parent_stage
      ci_job.parent_stage.destroy
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.reload.parent_stage).not_to be_nil
    end
  end

  context 'when parent_stage is nil and stage stage_in_progress' do
    let(:ci_job) { create(:ci_job, :test, :success, check_suite: check_suite) }
    let(:fake_translation) { create(:bamboo_stage_translation, start_in_progress: true) }
    let(:parent_stage) { create(:parent_stage, name: fake_translation.bamboo_stage_name, check_suite: check_suite) }
    let(:ci_jobs) do
      [
        { name: ci_job.name, job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
        { name: 'CHECKOUT', job_ref: 'CHECKOUT-1', stage: fake_translation.bamboo_stage_name }
      ]
    end

    before do
      BambooStageTranslation.all.destroy_all
      parent_stage
      ci_job.parent_stage.destroy
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.reload.parent_stage).not_to be_nil
    end
  end
end
