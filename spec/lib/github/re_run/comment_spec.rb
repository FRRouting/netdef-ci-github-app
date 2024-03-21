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
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil) }
  let(:fake_unavailable) { Github::Build::UnavailableJobs.new(nil) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

    allow(Github::Build::UnavailableJobs).to receive(:new).and_return(fake_unavailable)
    allow(fake_unavailable).to receive(:update).and_return([])
  end

  describe 'Invalid payload' do
    context 'when receives an empty payload' do
      let(:payload) { {} }

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(fake_github_check)
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
      end

      it 'must returns error' do
        expect(rerun.start).to eq([422, 'Payload can not be blank'])
      end
    end

    context 'when receives an invalid command' do
      let(:payload) do
        {
          'action' => 'delete',
          'comment' => { 'body' => 'CI:rerun' },
          'sender' => { 'login' => 'john' }
        }
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(fake_github_check)
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
        allow(fake_github_check).to receive(:pull_request_info)
          .and_return({ head: { ref: 'blah' } })
      end

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
      let!(:user) { create(:user, github_username: check_suite.pull_request.author) }

      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
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
          'issue' => { 'number' => check_suite.pull_request.github_pr_id },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }

      before do
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
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
        allow(fake_github_check).to receive(:pull_request_info)
          .and_return({ head: { ref: check_suite.commit_sha_ref } })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (comment)'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when receives a valid command but can save' do
      let!(:user) { create(:user, github_username: check_suite.pull_request.author) }

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
          'issue' => { 'number' => check_suite.pull_request.github_pr_id },
          'sender' => { 'login' => check_suite.pull_request.author }
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
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
        allow(fake_github_check).to receive(:pull_request_info)
          .and_return({ head: { ref: check_suite.commit_sha_ref } })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (comment)'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when has two opened PRs' do
      let!(:user) { create(:user, github_username: check_suite.pull_request.author) }
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
          'issue' => { 'number' => check_suite.pull_request.github_pr_id },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
      end

      let(:pull_request_info) do
        {
          head: {
            ref: check_suite.commit_sha_ref
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
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)

        another_check_suite
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (comment)'])
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
      let!(:user) { create(:user, github_username: check_suite.pull_request.author) }

      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
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
          'issue' => { 'number' => check_suite.pull_request.github_pr_id },
          'sender' => { 'login' => check_suite.pull_request.author }
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
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (comment)'])
        expect(check_suite_rerun).not_to be_nil
      end
    end

    context 'when max_retries is reached' do
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
      let(:ci_jobs) do
        [
          { name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1', stage: fake_translation.bamboo_stage_name },
          { name: 'Checkout', job_ref: 'CHK-01', stage: fake_translation.bamboo_stage_name }
        ]
      end
      let(:previous_check_suites) do
        create_list(:check_suite, 5,
                    re_run: true,
                    pull_request: check_suite.pull_request,
                    work_branch: check_suite.work_branch)
      end
      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000',
            'comment_id' => '10'
          },
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
      end
      let(:pull_request_commits) do
        [
          { sha: check_suite.commit_sha_ref, date: Time.now }
        ]
      end
      let(:group) { create(:group) }

      before do
        previous_check_suites
        group
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)
        allow(fake_github_check).to receive(:pull_request_info)
          .and_return({ head: { ref: check_suite.work_branch } })
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
        allow(fake_github_check).to receive(:comment_reaction_thumb_down)

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns error' do
        expect(rerun.start).to eq([402, 'No permission to run'])
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
      allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })

      allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
      allow(fake_plan_run).to receive(:start_plan).and_return(200)
      allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

      allow(BambooCi::StopPlan).to receive(:build)
      allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(bamboo_jobs)
    end

    context 'when you receive an comment and does not exist a PR' do
      let!(:user) { create(:user) }

      let(:commit_sha) { Faker::Internet.uuid }

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' },
          'sender' => { 'login' => 'john' }
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

      let(:fake_check_suite) { create(:check_suite) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: commit_sha, re_run: true) }

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (comment)'])
        expect(check_suite_rerun).not_to be_nil
      end
    end

    context 'when can not save check_suite' do
      let!(:user) { create(:user, github_username: check_suite.pull_request.author) }

      let(:commit_sha) { Faker::Internet.uuid }
      let(:check_suite) { create(:check_suite) }

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000'
          },
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' },
          'sender' => { 'login' => check_suite.pull_request.author }
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

      let(:fake_check_suite) { create(:check_suite) }

      before do
        create(:plan, github_repo_name: 'unit_test')
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })
      end

      it 'must returns success' do
        expect(rerun.start).to eq([404, 'Failed to create a check suite'])
      end
    end
  end
end
