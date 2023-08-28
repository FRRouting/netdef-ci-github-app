#  SPDX-License-Identifier: BSD-2-Clause
#
#  build_plan_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::BuildPlan do
  let(:build_plan) { described_class.new(payload) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil) }
  let(:fake_check_run) { create(:check_suite) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
  end

  describe 'Valid commands' do
    let(:pr_number) { rand(1_000_000) }
    let(:repo) { 'UnitTest/repo' }
    let(:payload) do
      {
        'action' => action,
        'number' => pr_number,
        'pull_request' => {
          'user' => {
            'login' => author
          },

          'head' => {
            'ref' => 'unit-test',
            'sha' => Digest::SHA2.hexdigest('abc')
          },

          'base' => {
            'ref' => 'master',
            'sha' => Digest::SHA2.hexdigest('123')
          }
        },
        'repository' => {
          'full_name' => repo
        }
      }
    end

    before do
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

      allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
    end

    context 'when action is opened' do
      let(:action) { 'opened' }
      let(:author) { 'Johnny Silverhand' }
      let(:ci_jobs) do
        [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }, { name: 'CHECKOUT', job_ref: 'CHECKOUT-1' }]
      end

      it 'must create a PR' do
        expect(build_plan.create).to eq([200, 'Pull Request created'])
      end
    end

    context 'when action is opened and check created_objects' do
      let(:action) { 'opened' }
      let(:author) { 'Johnny Silverhand' }
      let(:pull_request) { PullRequest.last }
      let(:check_suite) { pull_request.check_suites.last }
      let(:ci_job) { check_suite.ci_jobs.last }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:plan) { create(:plan, github_repo_name: repo) }

      before do
        plan
        build_plan.create
      end

      it 'must create all objects' do
        expect(pull_request.author).to eq(author)
        expect(pull_request.github_pr_id.to_i).to eq(pr_number)
        expect(pull_request.check_suites.to_a).not_to eq([])
        expect(check_suite.author).to eq(author)
        expect(ci_job.name).to eq('First Test')
        expect(ci_job.job_ref).to eq('UNIT-TEST-FIRST-1')
      end
    end

    context 'when commit and has a previous CI jobs' do
      let(:action) { 'opened' }
      let(:pull_request) { create(:pull_request, github_pr_id: pr_number, repository: repo) }
      let(:previous_check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:previous_ci_job) { previous_check_suite.reload.ci_jobs.last }
      let(:check_suite) { pull_request.reload.check_suites.last }
      let(:author) { 'Johnny Silverhand' }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:new_pull_request) { PullRequest.last }

      before do
        previous_check_suite

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(fake_github_check).to receive(:cancelled)

        build_plan.create
      end

      it 'must create a new check_suite' do
        expect(pull_request.author).to eq(new_pull_request.author)
        expect(check_suite.author).to eq(author)
        expect(previous_ci_job.status).to eq('cancelled')
      end
    end

    context 'when commit and has a previous CI jobs running' do
      let(:action) { 'opened' }
      let(:pull_request) { create(:pull_request, github_pr_id: pr_number, repository: repo) }
      let(:previous_check_suite) { create(:check_suite, :with_running_success_ci_jobs, pull_request: pull_request) }
      let(:previous_ci_job) { previous_check_suite.reload.ci_jobs.last }
      let(:check_suite) { pull_request.reload.check_suites.last }
      let(:author) { 'Johnny Silverhand' }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:new_pull_request) { PullRequest.last }

      let(:after_queued_jobs) { previous_check_suite.ci_jobs.where(status: 'queued').count }
      let(:after_in_progress_jobs) { previous_check_suite.ci_jobs.where(status: 'in_progress').count }
      let(:after_success_jobs) { previous_check_suite.ci_jobs.where(status: 'success').count }

      let!(:before_queued_jobs) { previous_check_suite.ci_jobs.where(status: 'queued').count }
      let!(:before_in_progress_jobs) { previous_check_suite.ci_jobs.reload.where(status: 'in_progress').count }
      let!(:before_success_jobs) { previous_check_suite.ci_jobs.reload.where(status: 'success').count }

      before do
        previous_check_suite

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(fake_github_check).to receive(:cancelled)

        build_plan.create
      end

      it 'must cancel only queued and in_progress jobs' do
        expect(before_queued_jobs).not_to eq(after_queued_jobs)
        expect(before_in_progress_jobs).not_to eq(after_in_progress_jobs)
        expect(before_success_jobs).to eq(after_success_jobs)
      end
    end
  end

  describe 'Invalid commands' do
    let(:pr_number) { 0 }
    let(:repo) { 'unit-test/xxx' }
    let(:payload) do
      {
        'action' => action,
        'number' => pr_number,
        'pull_request' => {
          'user' => {
            'login' => author
          },

          'head' => {
            'ref' => 'unit-test',
            'sha' => Digest::SHA2.hexdigest('abc')
          },

          'base' => {
            'ref' => 'master',
            'sha' => Digest::SHA2.hexdigest('123')
          }
        },
        'repository' => {
          'full_name' => repo
        }
      }
    end

    context 'when receives an invalid action' do
      let(:action) { 'fake' }
      let(:author) { 'Jack The Ripper' }

      it 'must returns an error' do
        expect(build_plan.create).to eq([405, "Not dealing with action \"#{payload['action']}\" for Pull Request"])
      end
    end

    context 'when receives an empty payload' do
      let(:action) { 'fake' }
      let(:author) { 'Jack The Ripper' }
      let(:payload) { {} }

      it 'must returns an error' do
        expect { build_plan.create }.to raise_error(StandardError)
      end
    end

    context 'when check suite does not persisted at database' do
      let(:author) { nil }
      let(:action) { 'synchronize' }
      let(:check_suite) { create(:check_suite) }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(CheckSuite).to receive(:create).and_return(check_suite)
        allow(check_suite).to receive(:persisted?).and_return(false)
      end

      it 'must returns an error' do
        expect(build_plan.create).to eq([422, 'Failed to save Check Suite'])
      end
    end

    context 'when failed to start CI' do
      let(:author) { 'Jonny Rocket' }
      let(:action) { 'synchronize' }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(400)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
      end

      it 'must returns an error' do
        expect(build_plan.create).to eq([400, 'Failed to create CI Plan'])
      end
    end

    context 'when failed to fetch the running plan' do
      let(:author) { 'Jonny Rocket' }
      let(:action) { 'synchronize' }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return([])
      end

      it 'must returns an error' do
        expect(build_plan.create).to eq([422, 'Failed to fetch RunningPlan'])
      end
    end
  end
end
