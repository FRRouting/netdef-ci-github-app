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
  let(:pull_request) { create(:pull_request, plans: [plan]) }
  let(:check_suite) { create(:check_suite, pull_request: pull_request, plan: plan) }
  let(:new_check_suite) { create(:check_suite, pull_request: pull_request, plan: plan, re_run: true) }
  let(:payload) do
    {
      'sender' => { 'login' => 'user', 'id' => 123, 'type' => 'User' }
    }
  end

  let(:fake_github_check) { instance_double(Github::Check, signature: 'sig') }
  let(:bamboo_plan_run_double) { instance_double(BambooCi::PlanRun) }
  let(:fake_action) { instance_double(Github::Build::Action) }

  before do
    allow(GithubLogger).to receive_message_chain(:instance, :create).and_return(Logger.new($stdout))
    allow(Logger).to receive(:new).and_return(Logger.new($stdout))

    allow(Github::Check).to receive(:new).and_return(fake_github_check)

    allow(BambooCi::PlanRun).to receive(:new).and_return(bamboo_plan_run_double)
    allow(bamboo_plan_run_double).to receive(:ci_variables=)
    allow(bamboo_plan_run_double).to receive(:start_plan).and_return(200)

    allow(AuditRetry).to receive(:create).and_return(instance_double(AuditRetry))
    allow(Github::UserInfo).to receive(:new)

    allow_any_instance_of(described_class).to receive(:stop_previous_execution)
    allow_any_instance_of(described_class).to receive(:cleanup)
    allow_any_instance_of(described_class).to receive(:ci_jobs)
    allow(CheckSuite).to receive(:create).and_return(new_check_suite)
    allow(SlackBot).to receive_message_chain(:instance, :execution_started_notification)
  end

  # ─── .create ─────────────────────────────────────────────────────────────────

  describe '.create' do
    context 'when check_suite does not exist' do
      it 'returns [404, "Failed to fetch a check suite"]' do
        result = described_class.create(plan.id, 999_999, payload)
        expect(result).to eq([404, 'Failed to fetch a check suite'])
      end
    end

    context 'when plan does not exist' do
      it 'returns [404, "Plan not found"]' do
        result = described_class.create(999_999, check_suite.id, payload)
        expect(result).to eq([404, 'Plan not found'])
      end
    end

    context 'when both plan and check_suite exist' do
      context 'and Bamboo submission succeeds' do
        it 'returns [200, "Scheduled Plan Runs"]' do
          result = described_class.create(plan.id, check_suite.id, payload)
          expect(result).to eq([200, 'Scheduled Plan Runs'])
        end
      end

      context 'and the new check_suite fails to persist' do
        before do
          unpersisted = build(:check_suite, pull_request: pull_request, plan: plan)
          allow(CheckSuite).to receive(:create).and_return(unpersisted)
        end

        it 'returns [422, "Failed to save Check Suite"]' do
          result = described_class.create(plan.id, check_suite.id, payload)
          expect(result).to eq([422, 'Failed to save Check Suite'])
        end
      end

      context 'and Bamboo submission fails' do
        before do
          allow(bamboo_plan_run_double).to receive(:start_plan).and_return(500)
        end

        it 'returns [500, "Failed to create CI Plan"]' do
          result = described_class.create(plan.id, check_suite.id, payload)
          expect(result).to eq([500, 'Failed to create CI Plan'])
        end
      end

      context 'and Bamboo returns 422' do
        before do
          allow(bamboo_plan_run_double).to receive(:start_plan).and_return(422)
        end

        it 'returns [422, "Failed to create CI Plan"]' do
          result = described_class.create(plan.id, check_suite.id, payload)
          expect(result).to eq([422, 'Failed to create CI Plan'])
        end
      end
    end
  end

  # ─── #create_check_suite ─────────────────────────────────────────────────────

  describe '#create_check_suite' do
    subject(:instance) do
      described_class.allocate.tap do |obj|
        obj.instance_variable_set(:@payload, payload)
        obj.instance_variable_set(:@logger_manager, [])
        obj.instance_variable_set(:@github_check, fake_github_check)
      end
    end

    it 'creates a new check_suite with re_run: true' do
      expect(CheckSuite).to receive(:create).with(
        hash_including(
          pull_request: check_suite.pull_request,
          plan: plan,
          re_run: true
        )
      ).and_return(new_check_suite)

      instance.create_check_suite(check_suite, plan)
    end

    it 'copies author, commit_sha_ref and branch fields from the original check_suite' do
      expect(CheckSuite).to receive(:create).with(
        hash_including(
          author: check_suite.author,
          commit_sha_ref: check_suite.commit_sha_ref,
          work_branch: check_suite.work_branch,
          base_sha_ref: check_suite.base_sha_ref,
          merge_branch: check_suite.merge_branch
        )
      ).and_return(new_check_suite)

      instance.create_check_suite(check_suite, plan)
    end

    it 'returns the newly created check_suite' do
      result = instance.create_check_suite(check_suite, plan)
      expect(result).to eq(new_check_suite)
    end
  end

  # ─── #start_new_execution ────────────────────────────────────────────────────

  describe '#start_new_execution' do
    subject(:instance) do
      described_class.allocate.tap do |obj|
        obj.instance_variable_set(:@payload, payload)
        obj.instance_variable_set(:@logger_manager, [])
        obj.instance_variable_set(:@logger_level, Logger::INFO)
        obj.instance_variable_set(:@github_check, fake_github_check)
      end
    end

    before do
      allow(instance).to receive(:cleanup)
      allow(instance).to receive(:ci_vars).and_return([])
    end

    it 'returns the Bamboo status code from start_plan' do
      allow(bamboo_plan_run_double).to receive(:start_plan).and_return(200)
      expect(instance.start_new_execution(new_check_suite, plan)).to eq(200)
    end

    it 'returns non-200 Bamboo status without raising' do
      allow(bamboo_plan_run_double).to receive(:start_plan).and_return(500)
      expect(instance.start_new_execution(new_check_suite, plan)).to eq(500)
    end

    it 'creates an AuditRetry record with sender details' do
      expect(AuditRetry).to receive(:create).with(
        hash_including(
          check_suite: new_check_suite,
          github_username: 'user',
          github_id: 123,
          github_type: 'User',
          retry_type: 'full'
        )
      )

      instance.start_new_execution(new_check_suite, plan)
    end

    it 'calls cleanup before starting a new Bamboo run' do
      expect(instance).to receive(:cleanup).with(new_check_suite).ordered
      expect(bamboo_plan_run_double).to receive(:start_plan).ordered.and_return(200)

      instance.start_new_execution(new_check_suite, plan)
    end
  end

  # ─── integration: @status assignment ────────────────────────────────────────

  describe '@status assignment throughout the flow' do
    it 'is [200, "Scheduled Plan Runs"] on the happy path' do
      result = described_class.create(plan.id, check_suite.id, payload)
      expect(result).to eq([200, 'Scheduled Plan Runs'])
    end

    it 'is never nil' do
      result = described_class.create(plan.id, check_suite.id, payload)
      expect(result).not_to be_nil
    end

    context 'when check_suite persistence fails' do
      before do
        unpersisted = build(:check_suite, pull_request: pull_request, plan: plan)
        allow(CheckSuite).to receive(:create).and_return(unpersisted)
      end

      it 'does not call ci_jobs' do
        expect_any_instance_of(described_class).not_to receive(:ci_jobs)
        described_class.create(plan.id, check_suite.id, payload)
      end

      it 'does not call start_new_execution' do
        expect_any_instance_of(described_class).not_to receive(:start_new_execution)
        described_class.create(plan.id, check_suite.id, payload)
      end
    end

    context 'when Bamboo submission fails' do
      before { allow(bamboo_plan_run_double).to receive(:start_plan).and_return(503) }

      it 'does not call ci_jobs' do
        expect_any_instance_of(described_class).not_to receive(:ci_jobs)
        described_class.create(plan.id, check_suite.id, payload)
      end
    end
  end
end
