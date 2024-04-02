#  SPDX-License-Identifier: BSD-2-Clause
#
#  command_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun::Command do
  let(:rerun) { described_class.new(payload) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_plan_run) { BambooCi::PlanRun.new(nil) }
  let(:group) { create(:group) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
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
  end

  describe 'valid payload' do
    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }
    let(:fake_translation) { create(:stage_configuration) }

    context 'when receives a valid command' do
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
          'check_suite' => {
            'head_sha' => check_suite.commit_sha_ref,
            'pull_requests' => [
              { 'number' => check_suite.pull_request.github_pr_id }
            ]
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }
      let(:feature) { create(:feature, max_rerun_per_pull_request: 0) }
      let(:group) { create(:group, feature: feature) }
      let(:user) { create(:user, github_username: check_suite.pull_request.author, group: group) }
      let(:fake_unavailable_jobs) { Github::Build::UnavailableJobs.new(check_suite) }

      before do
        user

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
        allow(fake_github_check).to receive(:skipped)
        allow(fake_github_check).to receive(:fetch_username).and_return({})
        allow(fake_github_check).to receive(:pull_request_info)
          .and_return({ head: { ref: check_suite.commit_sha_ref } })
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })

        allow(Github::Build::UnavailableJobs).to receive(:new).and_return(fake_unavailable_jobs)
        allow(fake_unavailable_jobs).to receive(:update)

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return(any_args)

        allow(BambooCi::StopPlan).to receive(:build)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run (command)'])
        expect(check_suites.size).to eq(2)
        expect(check_suites.first.re_run).to be_falsey
        expect(check_suites.last.re_run).to be_truthy
      end
    end

    context 'when receives a valid command but invalid PR ID' do
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
          'issue' => { 'number' => 0 },
          'check_suite' => {
            'head_sha' => check_suite.commit_sha_ref,
            'pull_requests' => [
              { 'number' => 0 }
            ]
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
      end
      let(:check_suites) { CheckSuite.where(commit_sha_ref: check_suite.commit_sha_ref) }
      let(:user) { create(:user, github_username: check_suite.pull_request.author) }

      before do
        user
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
          .and_return({ head: { ref: check_suite.commit_sha_ref } })
        allow(fake_github_check).to receive(:fetch_username).and_return({ id: 1 })

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('CHK-01')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([404, 'Failed to fetch a check suite'])
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
          'check_suite' => {
            'head_sha' => check_suite.commit_sha_ref
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
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

    context 'when max_retries is reached and has invalid check_suite pull_requests' do
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
          'check_suite' => {
            'head_sha' => check_suite.commit_sha_ref,
            'pull_requests' => []
          },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'sender' => { 'login' => check_suite.pull_request.author }
        }
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
end
