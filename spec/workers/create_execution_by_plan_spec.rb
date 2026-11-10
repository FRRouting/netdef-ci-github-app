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
      allow(CheckSuite).to receive(:new).and_return(fake_suite)
      allow(fake_suite).to receive(:save).and_return(false)

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

    context 'when GitHub fails after the Bamboo plan has started' do
      let(:plan) { pull_request.plans.last }
      let(:delayed) { double('delayed') }

      before do
        allow(fake_action).to receive(:create_summary).and_raise(Octokit::NotFound)
        allow(described_class).to receive(:delay).and_return(delayed)
        allow(delayed).to receive(:setup_github_checks)
      end

      it 'does not raise, so Delayed Job does not run the job again' do
        expect(described_class.create(pull_request.id, payload, plan.id))
          .to eq([202, 'GitHub Checks setup rescheduled'])
      end

      it 'starts the Bamboo plan only once and creates a single check suite' do
        expect { described_class.create(pull_request.id, payload, plan.id) }
          .to change(CheckSuite, :count).by(1)
        expect(fake_plan_run).to have_received(:start_plan).once
      end

      it 'reschedules only the GitHub side for the same check suite' do
        described_class.create(pull_request.id, payload, plan.id)

        check_suite = pull_request.check_suites.reload.last
        expect(delayed).to have_received(:setup_github_checks).with(check_suite.id, plan.id, nil, 123)
      end
    end

    context 'when GitHub authentication fails before anything is saved' do
      let(:plan) { pull_request.plans.last }

      before do
        allow(Github::Check).to receive(:new).and_raise(Faraday::ConnectionFailed, 'execution expired')
      end

      it 'raises without leaving an orphan check suite or touching Bamboo' do
        pull_request
        count = CheckSuite.count

        expect { described_class.create(pull_request.id, payload, plan.id) }
          .to raise_error(Faraday::ConnectionFailed)
        expect(CheckSuite.count).to eq(count)
        expect(fake_plan_run).not_to have_received(:start_plan)
      end
    end

    context 'when the previous execution started in Bamboo but its GitHub setup never finished' do
      let(:plan) { pull_request.plans.last }
      let!(:previous) { create(:check_suite, pull_request: pull_request, plan: plan, bamboo_ci_ref: 'PR-24204') }

      before do
        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::StopPlan).to receive(:comment)
      end

      it 'stops the previous Bamboo build' do
        described_class.create(pull_request.id, payload, plan.id)

        expect(BambooCi::StopPlan).to have_received(:build).with(previous.bamboo_ci_ref)
      end
    end

    context 'when a check suite without a Bamboo build is newer than the running execution' do
      let(:plan) { pull_request.plans.last }
      let!(:running) do
        create(:check_suite, :with_stages, pull_request: pull_request, plan: plan, bamboo_ci_ref: 'PR-1')
      end

      before do
        create(:check_suite, pull_request: pull_request, plan: nil, bamboo_ci_ref: nil)
        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::StopPlan).to receive(:comment)
        allow(fake_github_check).to receive(:cancelled)
      end

      it 'ignores the check suite without a Bamboo build and stops the running one' do
        described_class.create(pull_request.id, payload, plan.id)

        expect(BambooCi::StopPlan).to have_received(:build).with(running.bamboo_ci_ref).once
      end

      it 'cancels the stages of the running execution' do
        described_class.create(pull_request.id, payload, plan.id)

        expect(running.stages.reload.map(&:status)).to all(eq('cancelled'))
      end
    end

    context 'when the previous execution has finished' do
      let(:plan) { pull_request.plans.last }

      before do
        create(:check_suite, pull_request: pull_request, plan: plan) do |suite|
          create(:stage, :success, check_suite: suite)
        end
        allow(BambooCi::StopPlan).to receive(:build)
      end

      it 'does not stop anything in Bamboo' do
        described_class.create(pull_request.id, payload, plan.id)

        expect(BambooCi::StopPlan).not_to have_received(:build)
      end
    end
  end

  describe '.setup_github_checks' do
    let(:plan) { pull_request.plans.last }
    let!(:previous) { create(:check_suite, pull_request: pull_request, plan: plan) }
    let!(:check_suite) { create(:check_suite, pull_request: pull_request, plan: plan) }

    before do
      allow(BambooCi::StopPlan).to receive(:comment)
    end

    it 'does not create a check suite nor start a Bamboo plan' do
      expect { described_class.setup_github_checks(check_suite.id, plan.id, previous.id, 123) }
        .not_to change(CheckSuite, :count)
      expect(BambooCi::PlanRun).not_to have_received(:new)
    end

    it 'resumes the GitHub checks of the same check suite' do
      described_class.setup_github_checks(check_suite.id, plan.id, previous.id, 123)

      expect(Github::Build::Action).to have_received(:new).with(check_suite, anything, anything, plan.name)
      expect(fake_action).to have_received(:create_summary).with(resume: true)
    end

    it 'returns 404 when the check suite no longer exists' do
      expect(described_class.setup_github_checks(0, plan.id, nil, 123))
        .to eq([404, 'Check Suite or Plan not found'])
    end
  end
end
