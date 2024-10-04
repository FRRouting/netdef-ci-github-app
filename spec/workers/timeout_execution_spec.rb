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

  context 'when timeout is called, but hanged' do
    let(:check_suite) { create(:check_suite) }

    before do
      allow(CheckSuite).to receive(:find).and_return(check_suite)
      allow(check_suite).to receive(:finished?).and_return(false)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(Time.now.utc - 3.hours)
      allow(finished_instance).to receive(:finished).and_return([200, 'Finished'])
    end

    it 'calls timeout job' do
      expect(described_class.timeout(check_suite.id)).to be_truthy
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
      allow(check_suite).to receive(:finished?).and_return(false)
      allow(check_suite).to receive(:last_job_updated_at_timer).and_return(Time.now.utc - 3.hours)
    end

    it 'calls timeout job' do
      expect(TimeoutExecution).to receive(:timeout)
      expect(described_class.timeout(check_suite.id)).to be_falsey
    end
  end

  # context 'when timeout is called and rescheduled' do
  #   let(:check_suite) { create(:check_suite) }
  #
  #   before do
  #     allow(CheckSuite).to receive(:find).and_return(check_suite)
  #     allow(check_suite).to receive(:finished?).and_return(true)
  #   end
  #
  #   it 'calls timeout job' do
  #     expect(described_class.timeout(check_suite.id)).to be_falsey
  #   end
  # end
end
