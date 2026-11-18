#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_comment_spec.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

describe CreateExecutionByComment do
  let(:pull_request) { create(:pull_request) }
  let(:plan) { create(:plan) }
  let(:payload) do
    {
      'comment' => { 'body' => 'ci:rerun #123456', 'user' => { 'login' => 'user' } },
      'action' => 'created'
    }
  end

  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil, pull_request.plans.last) }
  let(:fake_check_run) { create(:check_suite) }
  let(:fake_action) { double('Github::Build::Action') }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(TimeoutExecution).to receive_message_chain(:delay, :timeout).and_return(true)
    allow(GitHubApp::Configuration).to receive(:new).and_return(GitHubApp::Configuration.instance)

    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
    allow(fake_plan_run).to receive(:start_plan).and_return(200)
    allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-FIRST-1')
    allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHECKOUT-1')

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:create).and_return(fake_check_run)
    allow(fake_github_check).to receive(:in_progress).and_return(fake_check_run)
    allow(fake_github_check).to receive(:queued).and_return(fake_check_run)
    allow(fake_github_check).to receive(:fetch_username).and_return({})
    allow(fake_github_check).to receive(:fetch_username).and_return({})
    allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})
    allow(BambooCi::RunningPlan).to receive(:fetch).and_return({ job: '1' })
    allow(Github::Build::Action).to receive(:new).and_return(fake_action)
    allow(fake_action).to receive(:create_summary)

    allow(GithubLogger).to receive_message_chain(:instance, :create).and_return(Logger.new($stdout))
    allow(Logger).to receive(:new).and_return(Logger.new($stdout))
    allow(PullRequest).to receive(:find).and_return(pull_request)
    allow_any_instance_of(CreateExecutionByComment).to receive(:run_by_plan).and_return([201,
                                                                                         'Starting re-run (comment)'])
  end

  describe '.create' do
    it 'returns [422, "Plan not found"] if plan is nil' do
      expect(described_class.create(pull_request.id, payload, nil)).to eq([422, 'Plan not found'])
    end
  end

  describe '#fetch_last_commit_or_sha256' do
    it 'returns commit if commit exists and action matches ci:rerun # pattern' do
      instance = described_class.allocate
      # Corrige erro de @payload nil
      instance.instance_variable_set(:@payload, { 'repository' => { 'full_name' => 'repo/name' } })
      allow(instance).to receive(:action).and_return('ci:rerun #123456')
      commit = double('commit')
      allow(Github::Parsers::PullRequestCommit).to receive_message_chain(:new, :find_by_sha).and_return(commit)
      expect(instance.send(:fetch_last_commit_or_sha256)).to eq(commit)
    end
  end

  describe '#action?' do
    it 'returns true when action matches ci:rerun and payload action is created' do
      instance = described_class.allocate
      instance.instance_variable_set(:@payload, { 'action' => 'created' })
      allow(instance).to receive(:action).and_return('ci:rerun')
      expect(instance.send(:action?)).to be true
    end

    it 'returns false when action does not match ci:rerun' do
      instance = described_class.allocate
      instance.instance_variable_set(:@payload, { 'action' => 'created' })
      allow(instance).to receive(:action).and_return('other')
      expect(instance.send(:action?)).to be false
    end

    it 'returns false when payload action is not created' do
      instance = described_class.allocate
      instance.instance_variable_set(:@payload, { 'action' => 'edited' })
      allow(instance).to receive(:action).and_return('ci:rerun')
      expect(instance.send(:action?)).to be false
    end
  end

  describe '#run_by_plan' do
    let(:instance) do
      described_class.allocate.tap do |obj|
        obj.instance_variable_set(:@pull_request, pull_request)
        obj.instance_variable_set(:@payload, { 'repository' => { 'full_name' => pull_request.repository } })
        obj.instance_variable_set(:@logger_manager, [])
      end
    end

    before do
      allow_any_instance_of(described_class).to receive(:run_by_plan).and_call_original
      allow(pull_request).to receive(:plans).and_return(Plan.where(id: plan.id))
      Github::DuplicateRequestGuard.claim_rerun?(pull_request)
    end

    it 'keeps the rerun claim when the execution starts' do
      allow(instance).to receive(:start_by_plan).and_return([201, 'Starting re-run (comment)'])

      instance.send(:run_by_plan, plan)

      expect(pull_request.reload.rerun_requested_at).not_to be_nil
    end

    it 'releases the rerun claim when the execution does not start' do
      allow(instance).to receive(:start_by_plan).and_return([400, 'Failed to create CI Plan'])

      expect(instance.send(:run_by_plan, plan)).to eq([400, 'Failed to create CI Plan'])
      expect(pull_request.reload.rerun_requested_at).to be_nil
    end

    it 'releases the rerun claim and re-raises on an exception' do
      allow(instance).to receive(:start_by_plan).and_raise(RuntimeError, 'Bamboo down')

      expect { instance.send(:run_by_plan, plan) }.to raise_error(RuntimeError, 'Bamboo down')
      expect(pull_request.reload.rerun_requested_at).to be_nil
    end

    context 'when the rerun covers several plans' do
      let(:other_plan) { create(:plan) }

      before { allow(pull_request).to receive(:plans).and_return(Plan.where(id: [plan.id, other_plan.id])) }

      it 'keeps the rerun claim when one execution does not start' do
        allow(instance).to receive(:start_by_plan).and_return([400, 'Failed to create CI Plan'])

        instance.send(:run_by_plan, plan)

        expect(pull_request.reload.rerun_requested_at).not_to be_nil
      end

      it 'keeps the rerun claim and re-raises on an exception' do
        allow(instance).to receive(:start_by_plan).and_raise(RuntimeError, 'Bamboo down')

        expect { instance.send(:run_by_plan, plan) }.to raise_error(RuntimeError, 'Bamboo down')
        expect(pull_request.reload.rerun_requested_at).not_to be_nil
      end
    end
  end

  describe '#start_by_plan' do
    let(:check_suite) { create(:check_suite, pull_request: pull_request) }
    let(:instance) do
      described_class.allocate.tap do |obj|
        obj.instance_variable_set(:@pull_request, pull_request)
        obj.instance_variable_set(:@logger_manager, [])
      end
    end

    before do
      allow(instance).to receive(:sha256_or_comment?).and_return(check_suite)
      allow(instance).to receive(:stop_previous_execution)
      allow(instance).to receive(:ci_jobs)
    end

    it 'does not create the CI jobs when Bamboo refuses the plan' do
      allow(instance).to receive(:start_new_execution) { instance.instance_variable_set(:@plan_status, 418) }

      expect(instance.send(:start_by_plan, plan)).to eq([418, 'Failed to create CI Plan'])
      expect(instance).not_to have_received(:ci_jobs)
    end

    it 'creates the CI jobs when the plan starts' do
      allow(instance).to receive(:start_new_execution) { instance.instance_variable_set(:@plan_status, 200) }

      expect(instance.send(:start_by_plan, plan)).to eq([201, 'Starting re-run (comment)'])
      expect(instance).to have_received(:ci_jobs)
    end

    it 'returns 404 when no check suite can be created' do
      allow(instance).to receive(:sha256_or_comment?).and_return(nil)

      expect(instance.send(:start_by_plan, plan)).to eq([404, 'Failed to create a check suite'])
    end
  end
end
