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
    it 'creates the new check suite with the plan, so a later cleanup can find it' do
      allow(Github::Check).to receive(:new).and_return(double('Github::Check', signature: 'secret'))

      described_class.create(plan.id, check_suite.id, payload)

      expect(CheckSuite.where.not(id: check_suite.id).last.plan).to eq(plan)
    end

    context 'when the Bamboo plan does not start' do
      before do
        allow(BambooCi::PlanRun).to receive(:new)
          .and_return(double('BambooCi::PlanRun', 'ci_variables=': nil, start_plan: 500))
        Github::DuplicateRequestGuard.claim_rerun?(pull_request)
      end

      it 'does not create the CI jobs and frees the rerun claim' do
        allow_any_instance_of(described_class).to receive(:setup_github_checks)
        allow(Github::Check).to receive(:new).and_return(double('Github::Check', signature: 'secret'))

        expect(described_class.create(plan.id, check_suite.id, payload)).to eq([500, 'Failed to create CI Plan'])
        expect(pull_request.reload.rerun_requested_at).to be_nil
      end
    end

    context 'when the Bamboo plan starts' do
      before do
        allow(BambooCi::PlanRun).to receive(:new)
          .and_return(double('BambooCi::PlanRun', 'ci_variables=': nil, start_plan: 200))
        Github::DuplicateRequestGuard.claim_rerun?(pull_request)
      end

      it 'creates the GitHub checks and keeps the rerun claim' do
        allow_any_instance_of(described_class).to receive(:setup_github_checks)
        allow(Github::Check).to receive(:new).and_return(double('Github::Check', signature: 'secret'))

        expect(described_class.create(plan.id, check_suite.id, payload)).to eq([201, 'Starting re-run (command)'])
        expect(pull_request.reload.rerun_requested_at).not_to be_nil
      end
    end

    it 'returns [404, "Failed to fetch a check suite"] if check_suite is nil' do
      allow(CheckSuite).to receive(:find).with(999).and_return(nil)
      expect(described_class.create(plan.id, 999, payload)).to eq([404, 'Failed to fetch a check suite'])
    end
  end
end
