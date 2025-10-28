#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_command_spec.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

describe CreateExecutionByCommand do
  let(:plan) { create(:plan) }
  let(:pull_request) { create(:pull_request, plan: plan) }
  let(:check_suite) { create(:check_suite, pull_request: pull_request) }
  let(:payload) do
    {
      'sender' => { 'login' => 'user', 'id' => 123, 'type' => 'User' }
    }
  end

  before do
    allow(Plan).to receive(:find).with(plan.id).and_return(plan)
    allow(GithubLogger).to receive_message_chain(:instance, :create).and_return(Logger.new($stdout))
    allow(Logger).to receive(:new).and_return(Logger.new($stdout))
    allow(Github::Check).to receive(:new)
    allow_any_instance_of(CreateExecutionByCommand).to receive(:stop_previous_execution)
    allow_any_instance_of(CreateExecutionByCommand).to receive(:ci_jobs)
    allow_any_instance_of(CreateExecutionByCommand).to receive(:cleanup)
    bamboo_plan_run_double = double('BambooCi::PlanRun')
    allow(bamboo_plan_run_double).to receive(:ci_variables=)
    allow(bamboo_plan_run_double).to receive(:start_plan)
    allow(BambooCi::PlanRun).to receive(:new).and_return(bamboo_plan_run_double)
    allow(AuditRetry).to receive(:create)
    allow(Github::UserInfo).to receive(:new)
  end

  describe '.create' do
    it 'returns [404, "Failed to fetch a check suite"] if check_suite is nil' do
      allow(CheckSuite).to receive(:find).with(999).and_return(nil)
      expect(described_class.create(plan.id, 999, payload)).to eq([404, 'Failed to fetch a check suite'])
    end
  end
end
