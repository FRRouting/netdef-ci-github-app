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

  describe '#comment_stopped_executions' do
    let(:stopped_suite) { create(:check_suite, bamboo_ci_ref: 'PLAN-10') }
    let(:other_stopped_suite) { create(:check_suite, bamboo_ci_ref: 'PLAN-11') }
    let(:new_suite) { create(:check_suite, bamboo_ci_ref: 'PLAN-12') }

    before do
      allow(BambooCi::StopPlan).to receive(:build)
      allow(BambooCi::StopPlan).to receive(:comment)
      allow(rerun).to receive(:cancel_previous_jobs)
    end

    context 'when previous executions were stopped' do
      before do
        rerun.send(:stop_and_update_previous_execution, stopped_suite)
        rerun.send(:stop_and_update_previous_execution, other_stopped_suite)
        rerun.send(:comment_stopped_executions, new_suite)
      end

      it 'comments the new execution on each stopped Bamboo result' do
        expect(BambooCi::StopPlan).to have_received(:comment).with(stopped_suite, new_suite)
        expect(BambooCi::StopPlan).to have_received(:comment).with(other_stopped_suite, new_suite)
      end
    end

    context 'when the new execution has no Bamboo reference' do
      let(:new_suite) { create(:check_suite, bamboo_ci_ref: nil) }

      before do
        rerun.send(:stop_and_update_previous_execution, stopped_suite)
        rerun.send(:comment_stopped_executions, new_suite)
      end

      it 'does not comment' do
        expect(BambooCi::StopPlan).not_to have_received(:comment)
      end
    end

    context 'when Bamboo refuses to stop a previous execution' do
      before do
        allow(BambooCi::StopPlan).to receive(:stop_execution).with(stopped_suite.bamboo_ci_ref).and_return(false)
        rerun.send(:stop_and_update_previous_execution, stopped_suite)
        rerun.send(:comment_stopped_executions, new_suite)
      end

      it 'neither cancels its checks nor comments that it was cancelled' do
        expect(rerun).not_to have_received(:cancel_previous_jobs)
        expect(BambooCi::StopPlan).not_to have_received(:comment)
      end
    end

    context 'when nothing was stopped' do
      before { rerun.send(:comment_stopped_executions, new_suite) }

      it 'does not comment' do
        expect(BambooCi::StopPlan).not_to have_received(:comment)
      end
    end
  end
end
