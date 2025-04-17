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
  let(:fake_finish_plan) { Github::PlanExecution::Finished.new({ 'bamboo_ref' => 'UBUNTU-1' }) }
  let(:pull_request) { create(:pull_request) }
  let(:check_suite) { create(:check_suite, pull_request: pull_request) }
  let(:position1) { BambooStageTranslation.find_by_position(1) }
  let(:position2) { BambooStageTranslation.find_by_position(2) }
  let(:parent_stage1) { create(:stage, check_suite: check_suite, name: position1.github_check_run_name) }
  let(:parent_stage2) { create(:stage, check_suite: check_suite, name: position2.github_check_run_name) }

  before do
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::PlanExecution::Finished).to receive(:new).and_return(fake_finish_plan)
    allow(fake_finish_plan).to receive(:fetch_build_status)

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
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:second_stage_config) { create(:stage_configuration, position: 2) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:second_stage) { create(:stage, configuration: second_stage_config, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job2) { create(:ci_job, :in_progress, check_suite: check_suite, stage: second_stage) }

    before do
      ci_job
      ci_job2
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('success')
      expect(ci_job2.stage.reload.status).to eq('in_progress')
    end
  end

  context 'when the build stage finished unsuccessfully' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:second_stage_config) { create(:stage_configuration, position: 2) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:second_stage) { create(:stage, configuration: second_stage_config, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :failure, check_suite: check_suite, stage: first_stage) }
    let(:ci_job2) { create(:ci_job, :in_progress, check_suite: check_suite, stage: second_stage) }

    before do
      ci_job
      ci_job2
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('failure')
      expect(ci_job2.stage.reload.status).to eq('cancelled')
    end
  end

  context 'when the build stage still running' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job_running) { create(:ci_job, :in_progress, check_suite: check_suite, stage: first_stage) }

    before do
      ci_job
      ci_job_running
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('in_progress')
      expect(ci_job_running.stage.reload.status).to eq('in_progress')
    end
  end

  context 'when the tests stage finished successfully' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job2) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }

    before do
      ci_job
      ci_job2

      described_class.new(ci_job).build_summary
    end

    it 'must update stage' do
      expect(ci_job.stage.reload.status).to eq('success')
      expect(ci_job2.stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage finished unsuccessfully' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:second_stage_config) { create(:stage_configuration, position: 2) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:second_stage) { create(:stage, configuration: second_stage_config, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job) { create(:ci_job, :failure, check_suite: check_suite, stage: second_stage) }

    before do
      ci_job
      ci_job2
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('failure')
      expect(ci_job2.stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage finished unsuccessfully and build_message returns null' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:second_stage_config) { create(:stage_configuration, position: 2) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:second_stage) { create(:stage, name: 'Build', configuration: second_stage_config, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job) { create(:ci_job, :failure, name: 'Ubuntu Build', check_suite: check_suite, stage: second_stage) }

    before do
      ci_job
      ci_job2

      allow(BambooCi::Result).to receive(:fetch).and_return({})
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('failure')
      expect(ci_job2.stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage finished unsuccessfully and build_message returns errorlog' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:second_stage_config) { create(:stage_configuration, position: 2) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:second_stage) { create(:stage, name: 'Build', configuration: second_stage_config, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job) { create(:ci_job, :failure, name: 'Ubuntu Build', check_suite: check_suite, stage: second_stage) }

    let(:bamboo_result) do
      {
        'artifacts' =>
          {
            'artifact' =>
              [
                {
                  'name' => 'ErrorLog',
                  'link' => {
                    'href' => 'https://ci1.netdef.org/browse/UBUNTU-BUILD-1/artifact/shared/ErrorLog/ErrorLog'
                  }
                }
              ]
          }
      }
    end

    before do
      ci_job
      ci_job2

      allow(BambooCi::Result).to receive(:fetch).and_return(bamboo_result)
      allow(BambooCi::Download).to receive(:build_log).and_return('ErrorLog')
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('failure')
      expect(ci_job2.stage.reload.status).to eq('success')
    end
  end

  context 'when the tests stage still running' do
    let(:first_stage_config) { create(:stage_configuration, position: 1) }
    let(:first_stage) { create(:stage, configuration: first_stage_config, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, check_suite: check_suite, stage: first_stage) }
    let(:ci_job_running) { create(:ci_job, :in_progress, check_suite: check_suite, stage: first_stage) }

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.stage.reload.status).to eq('success')
      expect(ci_job_running.stage.reload.status).to eq('success')
    end
  end

  context 'when parent_stage is nil' do
    let(:ci_job) { create(:ci_job, :success, check_suite: check_suite, stage: nil) }
    let(:fake_translation) { create(:stage_configuration) }
    let(:stage) do
      create(:stage,
             name: fake_translation.bamboo_stage_name,
             check_suite: check_suite,
             configuration: fake_translation)
    end
    let(:ci_jobs) do
      [
        { name: ci_job.name, job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
        { name: 'CHECKOUT', job_ref: 'CHECKOUT-1', stage: fake_translation.bamboo_stage_name }
      ]
    end

    before do
      stage
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.reload.stage).not_to be_nil
    end
  end

  context 'when current stage is not mandatory and fail' do
    let(:stage1) { create(:stage, :build, check_suite: check_suite) }
    let(:stage2) { create(:stage, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :failure, stage: stage1, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, stage: stage2, check_suite: check_suite) }

    before do
      stage1.configuration.update(mandatory: false, position: 1)
      stage2.configuration.update(mandatory: true, position: 2)

      ci_job
      ci_job2
      summary.build_summary
    end

    it 'must not cancel next stage' do
      expect(stage1.reload.status).to eq('failure')
      expect(stage2.reload.status).to eq('queued')
    end
  end

  context 'when current stage is mandatory and fail' do
    let(:stage1) { create(:stage, :build, check_suite: check_suite) }
    let(:stage2) { create(:stage, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :failure, stage: stage1, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, stage: stage2, check_suite: check_suite) }

    before do
      stage1.configuration.update(position: 1)
      stage2.configuration.update(position: 2)

      ci_job
      ci_job2
      summary.build_summary
      summary.build_summary
    end

    it 'must cancel next stage' do
      expect(stage1.reload.status).to eq('failure')
      expect(stage2.reload.status).to eq('cancelled')
    end
  end

  context 'when parent_stage is nil and stage stage_in_progress' do
    let(:ci_job) { create(:ci_job, stage: nil, check_suite: check_suite) }
    let(:fake_translation) { create(:stage_configuration, start_in_progress: true) }
    let(:parent_stage) do
      create(:stage, name: fake_translation.bamboo_stage_name, check_suite: check_suite)
    end
    let(:ci_jobs) do
      [
        { name: ci_job.name, job_ref: 'UNIT-TEST-FIRST-1', stage: parent_stage.name },
        { name: 'CHECKOUT', job_ref: 'CHECKOUT-1', stage: parent_stage.name }
      ]
    end

    before do
      StageConfiguration.all.destroy_all
      parent_stage
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
    end

    it 'must update stage' do
      summary.build_summary
      expect(ci_job.reload.stage).not_to be_nil
    end
  end

  context 'when the current stage is cancelled' do
    let(:stage) { create(:stage, :cancelled, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, stage: stage, check_suite: check_suite) }

    before do
      ci_job
    end

    it 'does not update the stage' do
      expect { summary.build_summary }.not_to(change { stage.reload.status })
    end
  end

  context 'when stage does not exists' do
    let(:ci_job) { create(:ci_job, stage: nil, check_suite: check_suite) }
    let(:stage_configuration) { create(:stage_configuration, bamboo_stage_name: 'D', position: 1) }

    let(:current_stage) do
      create(:stage, name: 'B', check_suite: check_suite, configuration: create(:stage_configuration, position: 1))
    end

    let(:job_info) do
      [
        {
          name: ci_job.name,
          stage: 'D'
        }
      ]
    end

    before do
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(job_info)
      ci_job
      stage_configuration
    end

    it 'must create a new stage' do
      summary.build_summary
      expect(Stage.find(stage_configuration.id).name).to eq('D')
    end
  end

  context 'when the current stage is not mandatory and fails' do
    let(:stage1) { create(:stage, :build, check_suite: check_suite) }
    let(:stage2) { create(:stage, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :failure, stage: stage1, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, stage: stage2, check_suite: check_suite) }

    before do
      stage1.configuration.update(mandatory: false, position: 1)
      stage2.configuration.update(position: 2)

      ci_job
      ci_job2
      summary.build_summary
    end

    it 'does not cancel the next stage' do
      expect(stage1.reload.status).to eq('failure')
      expect(stage2.reload.status).to eq('queued')
    end
  end

  context 'when the current stage is mandatory and succeeds' do
    let(:stage1) { create(:stage, :build, check_suite: check_suite) }
    let(:stage2) { create(:stage, check_suite: check_suite) }
    let(:ci_job) { create(:ci_job, :success, stage: stage1, check_suite: check_suite) }
    let(:ci_job2) { create(:ci_job, stage: stage2, check_suite: check_suite) }

    before do
      stage1.configuration.update(mandatory: true, position: 1)
      stage2.configuration.update(position: 2)

      ci_job
      ci_job2
      summary.build_summary
    end

    it 'marks the next stage as in_progress' do
      expect(stage1.reload.status).to eq('success')
      expect(stage2.reload.status).to eq('in_progress')
    end
  end

  context 'when has a checkout message' do
    let(:stage) { create(:stage, :build, check_suite: check_suite) }
    let(:ci_job) do
      create(:ci_job, :success, stage: stage, check_suite: check_suite, name: 'Sourcecode', summary: 'HI')
    end
    let(:message) do
      "Sourcecode -> https://ci1.netdef.org/browse/#{ci_job.job_ref}\n```\nHI\n```"
    end

    it 'must update stage' do
      expect(summary.send(:generate_message, 'source', ci_job)).to include(message)
    end
  end

  context 'when has not a checkout message' do
    let(:stage) { create(:stage, :build, check_suite: check_suite) }
    let(:ci_job) do
      create(:ci_job, :success, stage: stage, check_suite: check_suite, name: 'Sourcecode')
    end
    let(:message) do
      "Sourcecode -> https://ci1.netdef.org/browse/#{ci_job.job_ref}\n```\nHI\n```"
    end

    it 'must update stage' do
      expect(summary.send(:generate_message, 'source', ci_job)).not_to include(message)
    end
  end
end
