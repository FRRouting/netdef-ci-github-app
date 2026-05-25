#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack_bot_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe TimeoutExecution do
  let(:timeout_execution) { described_class.instance }
  let(:finished_instance) { Github::PlanExecution::Finished.new({}) }

  before do
    allow(Github::PlanExecution::Finished).to receive(:new).and_return(finished_instance)
  end

  context 'when timeout is called, but still running' do
    let(:check_suite) { create(:check_suite) }

    before do
      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(true)
    end

    it 'calls timeout job' do
      expect(described_class.timeout(check_suite.id)).to be_falsey
    end
  end

  context 'when timeout is called and rescheduled' do
    let(:check_suite) { create(:check_suite) }

    before do
      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(false)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(Time.now.utc + 3.hours)
      allow(TimeoutExecution).to receive_message_chain(:delay, :timeout).and_return(true)
    end

    it 'calls timeout job' do
      expect(described_class.timeout(check_suite.id)).to be_falsey
    end
  end

  context 'when timeout is called, last update in 2 hour ago' do
    let(:check_suite) { create(:check_suite) }

    before do
      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(false, true)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(Time.now.utc - 3.hours)
    end

    it 'calls timeout job' do
      expect(described_class.timeout(check_suite.id)).to be_falsey
    end
  end

  context 'when timeout is called, last update in 2 hour ago and timeout is called' do
    let(:check_suite) { create(:check_suite) }
    let(:fake_github_check) { instance_double(Github::Check) }

    before do
      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(false, false)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(Time.now.utc + 3.hours,
                                                                           Time.now.utc - 3.hour)
      allow(finished_instance).to receive(:finished).and_return([200, 'Finished'])
      allow(Github::Check).to receive(:new).and_return(fake_github_check)
    end

    it 'calls timeout job' do
      expect(described_class.timeout(check_suite.id)).to be_falsey
    end
  end

  context 'when watchdog marks stale in_progress jobs as failure' do
    let(:check_suite) { create(:check_suite) }
    let(:fake_github_check) { instance_double(Github::Check) }
    let(:fake_summary) { instance_double(Github::Build::Summary, build_summary: nil) }
    let(:ci_job) { create(:ci_job, :in_progress, check_suite: check_suite) }

    before do
      ci_job.update_column(:updated_at, 3.hours.ago.utc)

      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(false)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(3.hours.ago.utc)
      allow(check_suite).to receive_message_chain(:ci_jobs, :where, :where).and_return([ci_job])
      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(Github::Build::Summary).to receive(:new).and_return(fake_summary)
      allow(ci_job).to receive(:failure)
    end

    it 'calls failure on each stale job and returns true' do
      expect(described_class.timeout(check_suite.id)).to be_truthy
    end

    it 'marks stale jobs as failure' do
      described_class.timeout(check_suite.id)

      expect(ci_job).to have_received(:failure).with(fake_github_check, agent: 'TimeoutExecution')
    end

    it 'builds summary for each stale job' do
      described_class.timeout(check_suite.id)

      expect(fake_summary).to have_received(:build_summary)
    end
  end
end
