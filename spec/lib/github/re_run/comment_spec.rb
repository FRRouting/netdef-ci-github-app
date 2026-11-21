#  SPDX-License-Identifier: BSD-2-Clause
#
#  re_run_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun::Comment do
  let(:rerun) { described_class.new(payload) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil, pull_request.plans.last) }
  let(:fake_unavailable) { Github::Build::UnavailableJobs.new(nil) }
  let!(:pull_request) { create(:pull_request, :with_check_suite, id: 1) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

    allow(Github::Build::UnavailableJobs).to receive(:new).and_return(fake_unavailable)
    allow(fake_unavailable).to receive(:update).and_return([])

    allow(TimeoutExecution).to receive_message_chain(:delay, :timeout).and_return(true)
  end

  describe 'Invalid payload' do
    context 'when receives an empty payload' do
      let(:payload) { {} }

      it 'must returns error' do
        expect(rerun.start).to eq([422, 'Payload can not be blank'])
      end
    end

    context 'when receives an invalid command' do
      let(:payload) { { 'action' => 'delete', 'comment' => { 'body' => 'CI:rerun' } } }

      it 'must returns error' do
        expect(rerun.start).to eq([404, 'Action not found'])
      end
    end
  end

  describe 'Valid payload' do
    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }
    let(:fake_translation) { create(:stage_configuration) }

    context 'when receives a valid command' do
      let(:pull_request) { create(:pull_request, github_pr_id: 22, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:previous_check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
          { name: 'Checkout', job_ref: 'CHK-01', stage: fake_translation.bamboo_stage_name }
        ]
      end
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => "CI:rerun ##{check_suite.commit_sha_ref}", 'id' => 1 },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }

      before do
        previous_check_suite
        check_suite

        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when receives the same command twice in a row' do
      let(:pull_request) { create(:pull_request, github_pr_id: 22, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:ci_jobs) do
        [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }]
      end
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => "CI:rerun ##{check_suite.commit_sha_ref}", 'id' => 1 },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }

      before do
        check_suite

        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive_messages(create: check_suite, fetch_username: {}, check_runs_for_ref: {})
        %i[add_comment cancelled in_progress queued comment_reaction_thumb_up].each do |method|
          allow(fake_github_check).to receive(method)
        end

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive_messages(start_plan: 200, bamboo_reference: 'CHK-01')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
      end

      it 'schedules only the first one' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(described_class.new(payload).start).to eq([202, 'Rerun already scheduled'])
        expect(check_suites.size).to eq(2)
      end

      it 'reacts only to the request that was scheduled' do
        rerun.start
        described_class.new(payload).start

        expect(fake_github_check).to have_received(:comment_reaction_thumb_up).once
      end

      it 'enqueues the plan id instead of the Plan record' do
        allow(CreateExecutionByComment).to receive(:create).and_call_original

        rerun.start

        pull_request.plans.each do |plan|
          expect(CreateExecutionByComment).to have_received(:create).with(pull_request.id, payload, plan.id)
        end
      end

      it 'schedules the plan runs even when GitHub refuses the reaction' do
        allow(fake_github_check).to receive(:comment_reaction_thumb_up).and_raise(Octokit::Forbidden)

        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when receives a valid command but can save' do
      let(:pull_request) { create(:pull_request) }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
          { name: 'Checkout', job_ref: 'CHK-01', stage: fake_translation.bamboo_stage_name }
        ]
      end
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => "CI:rerun ##{check_suite.commit_sha_ref}", 'id' => 1 },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }
      let(:fake_ci_job) { CiJob.new }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when has two opened PRs' do
      let(:first_pr) { create(:pull_request, github_pr_id: 12, id: 11, repository: 'test') }
      let(:second_pr) { create(:pull_request, github_pr_id: 13, id: 12, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: first_pr) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }
      let(:another_check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: second_pr) }
      let(:ci_jobs) do
        [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }]
      end

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun potato',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: check_suite.base_sha_ref
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
        allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)

        another_check_suite
      end

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suite_rerun).not_to be_nil
      end

      it 'must have 2 CheckSuites in first PR' do
        rerun.start
        expect(first_pr.check_suites.size).to eq(2)
      end

      it 'must have 1 CheckSuites in second PR' do
        rerun.start
        expect(second_pr.check_suites.size).to eq(1)
      end
    end

    context 'when you receive an comment' do
      let(:pull_request) { create(:pull_request, github_pr_id: 12, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }

      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }
        ]
      end

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => "CI:rerun 000000 ##{check_suite.commit_sha_ref}",
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: check_suite.base_sha_ref
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
        allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suite_rerun).not_to be_nil
      end
    end

    context 'when the pull request has no associated plans (legacy)' do
      let(:plan) { create(:plan, github_repo_name: 'test') }
      let(:pull_request) { create(:pull_request, github_pr_id: 22, repository: 'test', plans: []) }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:fake_plan_run) { BambooCi::PlanRun.new(nil, plan) }
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => "CI:rerun ##{check_suite.commit_sha_ref}", 'id' => 1,
                         'user' => { 'login' => 'John' } },
          'repository' => { 'full_name' => 'test' },
          'issue' => { 'number' => pull_request.github_pr_id }
        }
      end

      before do
        plan
        check_suite

        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        # The rerun now needs Bamboo to list the jobs of the new build before it creates the checks.
        allow(BambooCi::RunningPlan).to receive(:fetch)
          .and_return([{ name: 'Checkout', job_ref: 'CHK-01', stage: create(:stage_configuration).bamboo_stage_name }])
      end

      it 'must return success using plans from repository' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suites.size).to eq(2)
        expect(check_suites.last.re_run).to be_truthy
      end
    end

    context 'when receives an invalid pull request' do
      let(:pull_request) { create(:pull_request, github_pr_id: 12, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }

      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }
        ]
      end

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: check_suite.base_sha_ref
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
        allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

        allow(PullRequest).to receive(:find_by).and_return(nil)
      end

      it 'must returns failure' do
        expect(rerun.start).to eq([404, 'Pull Request not found'])
      end
    end

    context 'when receives a valid pull request but without check_suites' do
      let(:pull_request) { create(:pull_request, github_pr_id: 12, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }

      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }
        ]
      end

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: check_suite.base_sha_ref
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
        allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

        allow(PullRequest).to receive(:find_by).and_return(pull_request)
        allow(pull_request).to receive(:check_suites).and_return([])
      end

      it 'must returns failure' do
        expect(rerun.start).to eq([404, 'Can not rerun a new PullRequest'])
      end
    end

    context 'when you receive an comment' do
      let(:pull_request) { create(:pull_request, github_pr_id: 12, repository: 'test') }
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs, pull_request: pull_request) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }

      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name }
        ]
      end

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => "CI:rerun 000000 ##{check_suite.commit_sha_ref}",
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: check_suite.base_sha_ref
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
        allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:queued)
        allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).and_return(ci_jobs)

        allow(CheckSuite).to receive(:create).and_return(check_suite)
        allow(check_suite).to receive(:persisted?).and_return(false)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
      end
    end
  end

  describe 'alternative scenarios' do
    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }
    let(:fake_translation) { create(:stage_configuration) }

    before do
      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
      allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(fake_github_check).to receive(:create).and_return(fake_check_suite)
      allow(fake_github_check).to receive(:add_comment)
      allow(fake_github_check).to receive(:cancelled)
      allow(fake_github_check).to receive(:queued)
      allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)
      allow(fake_github_check).to receive(:fetch_username).and_return({})
      allow(fake_github_check).to receive(:check_runs_for_ref).and_return({})

      allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
      allow(fake_plan_run).to receive(:start_plan).and_return(200)
      allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

      allow(BambooCi::StopPlan).to receive(:build)
      allow(BambooCi::RunningPlan).to receive(:fetch).and_return(bamboo_jobs)
    end

    context 'when you receive an comment and does not exist a PR' do
      let(:commit_sha) { Faker::Internet.uuid }

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => pull_request.repository },
          'issue' => { 'number' => pull_request.github_pr_id }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: 'master'
          },
          base: {
            ref: 'test',
            sha: commit_sha
          }
        }
      end

      let(:pull_request_commits) do
        [
          { sha: commit_sha, date: Time.now }
        ]
      end

      let(:bamboo_jobs) do
        [
          { name: 'test', job_ref: 'checkout-01', stage: fake_translation.bamboo_stage_name }
        ]
      end

      let(:fake_check_suite) { create(:check_suite, pull_request: pull_request) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: commit_sha, re_run: true) }

      it 'must returns success' do
        expect(rerun.start).to eq([200, 'Scheduled Plan Runs'])
        expect(check_suite_rerun).not_to be_nil
      end
    end
  end

  describe 'pull request lookup' do
    let(:pull_request) { create(:pull_request, github_pr_id: 42, repository: 'org/repo-a') }
    let(:payload) do
      {
        'action' => 'created',
        'comment' => { 'body' => 'ci:rerun', 'user' => { 'login' => 'John' } },
        'repository' => { 'full_name' => 'org/repo-b' },
        'issue' => { 'number' => 42 }
      }
    end

    before { create(:check_suite, pull_request: pull_request) }

    it 'does not use a pull request with the same number from another repository' do
      expect(described_class.new(payload).start).to eq([404, 'Pull Request not found'])
    end
  end

  describe '#cleanup' do
    let(:pull_request) { create(:pull_request) }
    let(:stopped_suite) { create(:check_suite, pull_request: pull_request) }
    let(:queued_only_suite) { create(:check_suite, pull_request: pull_request) }
    let(:refused_suite) { create(:check_suite, pull_request: pull_request) }
    let(:new_suite) { create(:check_suite, pull_request: pull_request) }
    let(:rerun) { described_class.new({}) }

    def timeout_job(suite_id)
      Delayed::Job.create!(
        queue: 'timeout_execution',
        handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'TimeoutExecution'\n" \
                 "method_name: :timeout\nargs:\n- #{suite_id}\n"
      )
    end

    def remaining_suite_ids
      Delayed::Job.pluck(:handler).map { |h| h[/args:\n- (\d+)/, 1] }
    end

    before do
      [stopped_suite, queued_only_suite, refused_suite, new_suite].each { |suite| timeout_job(suite.id) }
      timeout_job("#{stopped_suite.id}0")

      allow(rerun).to receive(:cancel_previous_jobs)
      allow(BambooCi::StopPlan).to receive(:stop_execution).and_return(true)
      allow(BambooCi::StopPlan).to receive(:stop_execution).with(refused_suite.bamboo_ci_ref).and_return(false)

      rerun.send(:stop_and_update_previous_execution, stopped_suite)
      rerun.send(:stop_and_update_previous_execution, refused_suite)
      rerun.send(:cleanup, new_suite)
    end

    it 'removes only the timeout workers of the executions it stopped' do
      expect(remaining_suite_ids).to contain_exactly(queued_only_suite.id.to_s, refused_suite.id.to_s,
                                                     new_suite.id.to_s, "#{stopped_suite.id}0")
    end
  end
end
