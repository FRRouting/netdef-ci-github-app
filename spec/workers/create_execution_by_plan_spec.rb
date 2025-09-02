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
  end
end
