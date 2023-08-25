#  SPDX-License-Identifier: BSD-2-Clause
#
#  re_run_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun do
  let(:rerun) { described_class.new(payload) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil) }

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

    context 'when receives a valid command' do
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }, { name: 'Checkout', job_ref: 'CHK-01' }] }
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
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check).to receive(:create).and_return(check_suite)
        allow(fake_github_check).to receive(:add_comment)
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when receives a valid command but can save' do
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }, { name: 'Checkout', job_ref: 'CHK-01' }] }
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
        allow(fake_github_check).to receive(:cancelled)
        allow(fake_github_check).to receive(:in_progress)
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)

        allow(CiJob).to receive(:create).and_return(fake_ci_job)
        allow(fake_ci_job).to receive(:persisted?).and_return(false)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when you receive an comment' do
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: check_suite.commit_sha_ref, re_run: true) }

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
        allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
        expect(check_suite_rerun).not_to be_nil
      end
    end
  end

  describe 'alternative scenarios' do
    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }

    before do
      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
      allow(fake_client).to receive(:pull_request_commits).and_return(pull_request_commits, [])

      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(fake_github_check).to receive(:create).and_return(fake_check_suite)
      allow(fake_github_check).to receive(:add_comment)
      allow(fake_github_check).to receive(:cancelled)
      allow(fake_github_check).to receive(:pull_request_info).and_return(pull_request_info)

      allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
      allow(fake_plan_run).to receive(:start_plan).and_return(200)
      allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

      allow(BambooCi::StopPlan).to receive(:stop)
      allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(bamboo_jobs)
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
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' }
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
          { name: 'test', job_ref: 'checkout-01' }
        ]
      end

      let(:fake_check_suite) { create(:check_suite) }
      let(:check_suite_rerun) { CheckSuite.find_by(commit_sha_ref: commit_sha, re_run: true) }

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
        expect(check_suite_rerun).not_to be_nil
      end
    end

    context 'when can not save check_suite' do
      let(:commit_sha) { Faker::Internet.uuid }

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000'
          },
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' }
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
          { name: 'test', job_ref: 'checkout-01' }
        ]
      end

      let(:fake_check_suite) { create(:check_suite) }

      before do
        create(:plan, github_repo_name: 'unit_test')
      end

      it 'must returns success' do
        expect(rerun.start).to eq([404, 'Failed to create a check suite'])
      end
    end

    context 'when commit id is invalid' do
      let(:commit_sha) { Faker::Internet.uuid }

      let(:payload) do
        {
          'action' => 'created',
          'comment' => {
            'body' => 'CI:rerun 000000',
            'user' => { 'login' => 'John' }
          },
          'repository' => { 'full_name' => 'unit_test' },
          'issue' => { 'number' => '10' }
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
          { name: 'test', job_ref: 'checkout-01' }
        ]
      end

      let(:fake_check_suite) { create(:check_suite) }

      before do
        create(:plan, github_repo_name: 'unit_test')
        allow(fake_github_check).to receive(:comment_reaction_thumb_up)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
      end
    end
  end
end
