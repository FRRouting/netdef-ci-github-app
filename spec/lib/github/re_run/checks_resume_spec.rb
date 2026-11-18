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
  let(:stopped_suite) { create(:check_suite, pull_request: pull_request) }
  let(:payload) { { 'sender' => { 'login' => 'user', 'id' => 1, 'type' => 'User' } } }
  let(:fake_github_check) { instance_double(Github::Check) }
  let(:fake_action) { instance_double(Github::Build::Action, create_summary: true) }

  describe '.schedule' do
    let(:delayed) { double('delayed', run: true) }

    before { allow(described_class).to receive(:delay).and_return(delayed) }

    it 'enqueues only the GitHub side, with the suites the rerun stopped' do
      expect(described_class.schedule('q', payload, check_suite, plan,
                                      { last: stopped_suite, stopped: [stopped_suite] }))
        .to eq([202, 'GitHub Checks setup rescheduled'])
      expect(described_class).to have_received(:delay).with(hash_including(queue: 'q'))
      expect(delayed).to have_received(:run)
        .with(payload, check_suite.id, plan.id, stopped_suite.id, [stopped_suite.id])
    end
  end

  describe '.run' do
    before do
      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(Github::UserInfo).to receive(:new)
      allow(Github::Build::Action).to receive(:new).and_return(fake_action)
      allow(Github::Build::UnavailableJobs).to receive(:new).and_return(double(update: true))
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ name: 'Checkout', job_ref: 'CHK-1', stage: 'S' }])
      allow(BambooCi::StopPlan).to receive(:comment)
      allow(SlackBot.instance).to receive(:execution_started_notification)
    end

    it 'returns 404 when the check suite is gone' do
      expect(described_class.run(payload, 0, plan.id, nil, [])).to eq([404, 'Check Suite or Plan not found'])
    end

    it 'creates the checks again without repeating the notifications and the Bamboo comments' do
      expect(described_class.run(payload, check_suite.id, plan.id, stopped_suite.id, [stopped_suite.id]))
        .to eq([201, 'Re-run GitHub checks resumed'])

      expect(fake_action).to have_received(:create_summary).with(rerun: true, resume: true)
      expect(SlackBot.instance).not_to have_received(:execution_started_notification)
      expect(BambooCi::StopPlan).not_to have_received(:comment)
      expect(check_suite.reload.cancelled_previous_check_suite).to eq(stopped_suite)
    end

    it 'does not record the retry audit twice' do
      AuditRetry.create(check_suite: check_suite, retry_type: 'full')

      expect { described_class.run(payload, check_suite.id, plan.id, nil, []) }.not_to change(AuditRetry, :count)
    end
  end
end
