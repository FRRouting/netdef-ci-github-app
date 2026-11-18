#  SPDX-License-Identifier: BSD-2-Clause
#
#  checks_resume_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun::ChecksResume do
  let(:pull_request) { create(:pull_request) }
  let(:plan) { create(:plan) }
  let(:check_suite) { create(:check_suite, pull_request: pull_request) }
  let(:payload) { { 'sender' => { 'login' => 'user', 'id' => 1, 'type' => 'User' } } }
  let(:fake_github_check) { instance_double(Github::Check) }
  let(:fake_action) { instance_double(Github::Build::Action, create_summary: true) }

  describe '.schedule' do
    let(:delayed) { double('delayed', run: true) }

    before { allow(ResumeRerunChecks).to receive(:delay).and_return(delayed) }

    it 'enqueues only the GitHub side, through the worker' do
      expect(described_class.schedule('q', payload, check_suite, plan)).to eq([202, 'GitHub Checks setup rescheduled'])
      expect(ResumeRerunChecks).to have_received(:delay).with(hash_including(queue: 'q'))
      expect(delayed).to have_received(:run).with(payload, check_suite.id, plan.id)
    end
  end

  describe '#resume' do
    subject(:resume) { described_class.new(payload).resume(check_suite, plan) }

    before do
      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(Github::UserInfo).to receive(:new)
      allow(Github::Build::Action).to receive(:new).and_return(fake_action)
      allow(Github::Build::UnavailableJobs).to receive(:new).and_return(double(update: true))
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ name: 'Checkout', job_ref: 'CHK-1', stage: 'S' }])
      allow(BambooCi::StopPlan).to receive(:comment)
      allow(SlackBot.instance).to receive(:execution_started_notification)
    end

    it 'creates the checks again without repeating the notifications and the Bamboo comments' do
      expect(resume).to eq([201, 'Re-run GitHub checks resumed'])

      expect(fake_action).to have_received(:create_summary).with(rerun: true, resume: true)
      expect(SlackBot.instance).not_to have_received(:execution_started_notification)
      expect(BambooCi::StopPlan).not_to have_received(:comment)
    end

    it 'does not record the retry audit twice' do
      AuditRetry.create(check_suite: check_suite, retry_type: 'full')

      expect { resume }.not_to change(AuditRetry, :count)
    end

    context 'when a newer rerun replaced this one meanwhile' do
      let!(:check_suite) { create(:check_suite, pull_request: pull_request, plan: plan) }

      before do
        create(:check_suite, pull_request: pull_request, plan: plan)
        allow(BambooCi::StopPlan).to receive(:stop_execution).and_return(true)
        allow(Github::Build::OpenChecks).to receive(:cancel)
      end

      it 'stops its build and cancels its checks instead of creating them' do
        expect(resume).to eq([200, 'Superseded by a newer execution'])

        expect(BambooCi::StopPlan).to have_received(:stop_execution).with(check_suite.bamboo_ci_ref)
        expect(Github::Build::OpenChecks).to have_received(:cancel).with(check_suite, fake_github_check)
        expect(Github::Build::Action).not_to have_received(:new)
      end
    end
  end
end
