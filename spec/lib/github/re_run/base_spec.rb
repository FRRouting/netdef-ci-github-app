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

      # The rerun's own client points to the new suite, possibly on another commit.
      rerun.instance_variable_set(:@github_check, instance_double(Github::Check))
      allow(Github::Check).to receive(:new).with(check_suite).and_return(fake_github_check)
      rerun.send(:cancel_previous_jobs, check_suite)
    end

    it 'creates the cancelled checks on the commit of the stopped suite' do
      expect(fake_github_check).to have_received(:create).at_least(:once)
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

  describe '#setup_github_checks' do
    let(:rerun) { Class.new(described_class) { const_set(:QUEUE, 'rerun_queue') }.new({}) }
    let(:plan) { create(:plan) }

    before do
      allow(rerun).to receive(:record_full_retry)
      allow(rerun).to receive(:comment_stopped_executions)
      allow(rerun).to receive(:create_ci_jobs)
      allow(rerun).to receive(:update_unavailable_jobs)
      allow(SlackBot.instance).to receive(:execution_started_notification)
      allow(Github::ReRun::ChecksResume).to receive(:schedule).and_return([202, 'GitHub Checks setup rescheduled'])
    end

    it 'reschedules only the GitHub checks when they fail, instead of raising' do
      allow(rerun).to receive(:create_ci_jobs).and_raise(Octokit::ServerError)

      expect(rerun.send(:setup_github_checks, check_suite, plan)).to eq([202, 'GitHub Checks setup rescheduled'])
      expect(Github::ReRun::ChecksResume).to have_received(:schedule).with('rerun_queue', {}, check_suite, plan)
    end

    it 'announces the execution before anything that can be resumed fails' do
      allow(rerun).to receive(:record_full_retry).and_raise(Octokit::ServerError)

      rerun.send(:setup_github_checks, check_suite, plan)

      expect(SlackBot.instance).to have_received(:execution_started_notification).with(check_suite)
      expect(rerun).to have_received(:comment_stopped_executions).with(check_suite)
    end

    it 'does not let a Slack failure hold back the checks' do
      allow(SlackBot.instance).to receive(:execution_started_notification).and_raise(StandardError, 'slack down')

      rerun.send(:setup_github_checks, check_suite, plan)

      expect(rerun).to have_received(:create_ci_jobs)
      expect(Github::ReRun::ChecksResume).not_to have_received(:schedule)
    end

    it 'does not reschedule when the checks are created' do
      rerun.send(:setup_github_checks, check_suite, plan)

      expect(Github::ReRun::ChecksResume).not_to have_received(:schedule)
    end
  end

  describe '#release_claim_on_failure' do
    let(:pull_request) { create(:pull_request) }

    before do
      rerun.instance_variable_set(:@pull_request, pull_request)
      allow(rerun).to receive(:fetch_plans).and_return([create(:plan)])
      Github::DuplicateRequestGuard.claim_rerun?(pull_request)
    end

    it 'frees the claim and re-raises when the Bamboo plan did not start' do
      expect { rerun.send(:release_claim_on_failure) { raise 'Bamboo down' } }.to raise_error('Bamboo down')
      expect(pull_request.reload.rerun_requested_at).to be_nil
    end

    it 'keeps the claim and does not re-raise once the Bamboo plan started' do
      rerun.instance_variable_set(:@plan_status, 200)

      expect(rerun.send(:release_claim_on_failure) { raise 'DB down' })
        .to eq([201, 'Starting re-run (GitHub setup failed)'])
      expect(pull_request.reload.rerun_requested_at).not_to be_nil
    end
  end

  describe '#fetch_run_ci_by_pr' do
    let(:pull_request) { create(:pull_request, github_pr_id: 10, repository: 'Unit/Test') }
    let(:other_pull_request) { create(:pull_request, github_pr_id: 11, repository: 'Unit/Test') }
    let(:plan) { create(:plan, github_repo_name: 'Unit/Test', pull_request: other_pull_request) }
    let(:rerun) do
      described_class.new({ 'issue' => { 'number' => 10 }, 'repository' => { 'full_name' => 'Unit/Test' } })
    end
    let!(:running) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request, plan: plan) }

    before do
      create(:check_suite, :with_running_ci_jobs, pull_request: other_pull_request, plan: plan)
      create(:check_suite, :with_running_ci_jobs, pull_request: pull_request, plan: create(:plan))
      create(:check_suite, pull_request: pull_request, plan: plan)
    end

    it 'finds the running suite of the pull request even after its plan moved to another one' do
      expect(rerun.send(:fetch_run_ci_by_pr, plan)).to eq([running])
    end

    it 'stops nothing when the pull request has no running suite for the plan' do
      allow(BambooCi::StopPlan).to receive(:stop_execution)

      rerun.send(:stop_previous_execution, create(:plan, github_repo_name: 'Unit/Test'))

      expect(BambooCi::StopPlan).not_to have_received(:stop_execution)
    end

    it 'stops the running suite of the pull request' do
      allow(BambooCi::StopPlan).to receive(:stop_execution).and_return(true)
      allow(rerun).to receive(:cancel_previous_jobs)

      rerun.send(:stop_previous_execution, plan)

      expect(BambooCi::StopPlan).to have_received(:stop_execution).with(running.bamboo_ci_ref).once
      expect(rerun).to have_received(:cancel_previous_jobs).with(running)
    end

    it 'ignores a running suite without a plan when the repository has several plans' do
      create(:plan, github_repo_name: 'Unit/Test')
      create(:check_suite, :with_running_ci_jobs, pull_request: pull_request, plan: nil)

      expect(rerun.send(:fetch_run_ci_by_pr, plan)).to eq([running])
    end

    it 'also finds a running suite recorded without a plan' do
      legacy = create(:check_suite, :with_running_ci_jobs, pull_request: pull_request, plan: nil)

      expect(rerun.send(:fetch_run_ci_by_pr, plan)).to contain_exactly(running, legacy)
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

    context 'when the new execution is one of the stopped ones' do
      before do
        rerun.send(:stop_and_update_previous_execution, new_suite)
        rerun.send(:comment_stopped_executions, new_suite)
      end

      it 'does not comment on itself' do
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

  describe '#cleanup' do
    let(:stopped_suite) { create(:check_suite) }
    let(:new_suite) { create(:check_suite) }
    let(:pending_jobs) { double('pending', destroy_all: true) }

    before do
      allow(DelayedJobLookup).to receive(:pending).and_return(pending_jobs)
      rerun.instance_variable_set(:@stopped_check_suites, [stopped_suite, new_suite])
    end

    it 'removes the timeout workers of the stopped executions only' do
      rerun.send(:cleanup, new_suite)

      expect(DelayedJobLookup).to have_received(:pending).with(method: :timeout, first_arg: stopped_suite.id)
      expect(DelayedJobLookup).not_to have_received(:pending).with(method: :timeout, first_arg: new_suite.id)
    end
  end

  describe '#record_full_retry' do
    let(:check_suite) { create(:check_suite) }

    before { allow(Github::UserInfo).to receive(:new).and_raise(NoMethodError, 'rate limited') }

    it 'records the retry even when the user lookup fails' do
      expect { rerun.send(:record_full_retry, check_suite) }.not_to raise_error
      expect(AuditRetry.where(check_suite: check_suite, retry_type: 'full').count).to eq(1)
    end
  end
end
