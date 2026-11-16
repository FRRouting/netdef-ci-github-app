#  SPDX-License-Identifier: BSD-2-Clause
#
#  base_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun::Base do
  let(:rerun) { described_class.new({}) }
  let(:fake_github_check) { instance_double(Github::Check) }
  let(:check_suite) { create(:check_suite) }
  let(:running_stage) { create(:stage, :in_progress, check_suite: check_suite) }
  let(:queued_stage) { create(:stage, check_suite: check_suite, status: :queued) }
  let(:finished_stage) { create(:stage, check_suite: check_suite, status: :success) }
  let(:ci_job) { create(:ci_job, :in_progress, check_suite: check_suite, stage: running_stage) }

  describe '#cancel_previous_jobs' do
    before do
      ci_job
      queued_stage
      finished_stage

      allow(fake_github_check).to receive(:create).and_return(double(id: 1))
      allow(fake_github_check).to receive(:cancelled)
      allow(SlackBot.instance).to receive(:stage_finished_notification)

      rerun.instance_variable_set(:@github_check, fake_github_check)
      rerun.send(:cancel_previous_jobs, check_suite)
    end

    it 'cancels the jobs and the open stages of the previous execution' do
      expect(ci_job.reload.status).to eq('cancelled')
      expect(running_stage.reload.status).to eq('cancelled')
      expect(queued_stage.reload.status).to eq('cancelled')
    end

    it 'keeps the stages that already finished' do
      expect(finished_stage.reload.status).to eq('success')
    end
  end
end
