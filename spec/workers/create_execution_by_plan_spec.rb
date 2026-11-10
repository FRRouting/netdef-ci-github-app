#   SPDX-License-Identifier: BSD-2-Clause
#
#   create_execution_by_plan_spec.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true

describe CreateExecutionByPlan do
  let(:pull_request) { create(:pull_request, id: 25) }
  let(:payload) do
    {
      'pull_request' => {
        'user' => { 'login' => 'user', 'id' => 123 },
        'head' => { 'sha' => 'abc123', 'ref' => 'feature' },
        'base' => { 'sha' => 'def456', 'ref' => 'main' }
      }
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
  end

  describe '.create' do
    let(:fake_suite) { create(:check_suite) }
    it 'returns [422, "Plan not found"]' do
      allow(Plan).to receive(:find_by).and_return(nil)
      expect(described_class.create(pull_request.id, payload, 999)).to eq([422, 'Plan not found'])
    end

    it 'returns [422, "Failed to save Check Suite"]' do
      allow(CheckSuite).to receive(:create).and_return(fake_suite)
      allow(fake_suite).to receive(:persisted?).and_return(false)

      expect(described_class.create(pull_request.id, payload,
                                    pull_request.plans.last.id)).to eq([422, 'Failed to save Check Suite'])
    end

    it 'must create the execution' do
      result = described_class.create(pull_request.id, payload, pull_request.plans.last.id)
      expect(result).to eq([200, 'Pull Request created'])
    end

    context 'when plan does not exists' do
      it 'returns [422, "Plan not found"]' do
        allow(Plan).to receive(:find_by).and_return(nil)
        expect(described_class.create(pull_request.id, payload, 999)).to eq([422, 'Plan not found'])
      end
    end

    context 'when the pull request has a legacy check suite with no plan_id' do
      let(:legacy_pr) { create(:pull_request, plans: []) }
      let(:plan) { create(:plan) }
      let!(:legacy_check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: legacy_pr) }

      before do
        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::StopPlan).to receive(:comment)
        allow(fake_github_check).to receive(:cancelled)
      end

      it 'finds the legacy check suite and stops it' do
        described_class.create(legacy_pr.id, payload, plan.id)
        expect(legacy_check_suite.ci_jobs.reload.map(&:status)).to all(eq('cancelled'))
      end

      it 'creates a new check suite associated with the plan' do
        described_class.create(legacy_pr.id, payload, plan.id)
        new_suite = legacy_pr.check_suites.reload.last
        expect(new_suite).not_to eq(legacy_check_suite)
        expect(new_suite.plan).to eq(plan)
      end
    end

    # Regression: a GitHub API error after the Bamboo plan started used to propagate to
    # Delayed Job, which re-ran the whole job (new CheckSuite, stop of the plan just started,
    # start of another one) -> "Failed to prepare the build" on the Checkout Code job.
    context 'when the GitHub Checks setup fails after the Bamboo plan started' do
      let(:plan) { pull_request.plans.last }
      let(:delayed_proxy) { double('Delayed proxy') }

      before do
        allow(fake_action).to receive(:create_summary).and_raise(RuntimeError, 'GitHub API error')
        allow(described_class).to receive(:delay).and_return(delayed_proxy)
        allow(delayed_proxy).to receive(:setup_github_checks)
      end

      it 'does not raise, so Delayed Job does not re-run the whole job' do
        expect(described_class.create(pull_request.id, payload, plan.id))
          .to eq([202, 'GitHub Checks setup rescheduled'])
      end

      it 'starts the Bamboo plan only once' do
        described_class.create(pull_request.id, payload, plan.id)
        expect(fake_plan_run).to have_received(:start_plan).once
      end

      it 'reschedules only the GitHub side for the same check suite' do
        described_class.create(pull_request.id, payload, plan.id)
        expect(delayed_proxy).to have_received(:setup_github_checks).with(CheckSuite.last.id, plan.id, nil)
      end
    end
  end

  describe '.setup_github_checks' do
    let(:plan) { pull_request.plans.last }
    let(:check_suite) { create(:check_suite, pull_request: pull_request, plan: plan) }
    let(:running_jobs) do
      [{ name: 'Checkout Code', job_ref: 'CHECKOUT-1', stage: 'Get Sourcecode' },
       { name: 'Build', job_ref: 'BUILD-1', stage: 'Building Stage' }]
    end

    before do
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(running_jobs)
      allow(BambooCi::StopPlan).to receive(:build)
      allow(BambooCi::StopPlan).to receive(:comment)
    end

    it 'creates the GitHub Checks without touching Bamboo or creating a check suite' do
      check_suite

      expect { described_class.setup_github_checks(check_suite.id, plan.id, nil) }
        .not_to change(CheckSuite, :count)
      expect(BambooCi::PlanRun).not_to have_received(:new)
      expect(BambooCi::StopPlan).not_to have_received(:build)
      expect(fake_action).to have_received(:create_summary)
    end

    it 'skips CI jobs a previous attempt already created' do
      create(:ci_job, check_suite: check_suite, job_ref: 'CHECKOUT-1')

      described_class.setup_github_checks(check_suite.id, plan.id, nil)

      expect(Github::Build::Action).to have_received(:new).with(check_suite, anything, [running_jobs.last], plan.name)
    end

    it 'posts the "previous execution stopped" comment when it stopped a previous check suite' do
      previous = create(:check_suite, pull_request: pull_request, plan: plan)
      check_suite

      described_class.setup_github_checks(check_suite.id, plan.id, previous.id)

      expect(BambooCi::StopPlan).to have_received(:comment).with(previous, check_suite)
      expect(check_suite.reload.cancelled_previous_check_suite_id).to eq(previous.id)
    end

    it 'does nothing when a newer check suite superseded this one' do
      check_suite
      create(:check_suite, pull_request: pull_request, plan: plan)

      expect(described_class.setup_github_checks(check_suite.id, plan.id, nil))
        .to eq([200, 'CheckSuite superseded'])
      expect(Github::Build::Action).not_to have_received(:new)
    end
  end
end
