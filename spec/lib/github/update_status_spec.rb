#  SPDX-License-Identifier: BSD-2-Clause
#
#  update_status_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::UpdateStatus do
  let(:update_status) { described_class.new(payload) }
  let(:fake_unavailable) { Github::Build::UnavailableJobs.new(nil) }

  describe 'Validates different Ci Job status' do
    let(:payload) do
      {
        'status' => status,
        'bamboo_ref' => ci_job.job_ref
      }
    end

    let(:fake_client) { Octokit::Client.new }
    let(:fake_github_check) { Github::Check.new(nil) }

    before do
      allow(SlackBot.instance).to receive(:notify_success)
      allow(SlackBot.instance).to receive(:notify_success)
      allow(File).to receive(:read).and_return('')
      allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

      allow(Github::Check).to receive(:new).and_return(fake_github_check)
      allow(fake_github_check).to receive(:create).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:failure).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:in_progress).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:skipped).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:success).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:cancelled).and_return(ci_job.check_suite)
      allow(fake_github_check).to receive(:queued).and_return(ci_job.check_suite)

      allow(Github::Build::UnavailableJobs).to receive(:new).and_return(fake_unavailable)
    end

    context 'when Ci Job Checkout Code update from queued -> failure' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Code') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).to eq('queued') }
      end
    end

    context 'when Ci Job Checkout Code update from queued -> in_progress' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Code') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'in_progress' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
      end
    end

    context 'when Ci Job AMD Build update from in_progress -> failure' do
      let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).to eq('cancelled') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> failure' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'failure' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> failure + topotest_failures' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:status) { 'failure' }
      let(:payload) do
        {
          'status' => status,
          'bamboo_ref' => ci_job.job_ref,
          'failures' => [
            failure_info
          ]
        }
      end

      let(:failure) { TopotestFailure.find_by(ci_job: ci_job) }
      let(:failure_info) do
        {
          'suite' => 'test_ospf_sr_te_topo1',
          'case' => 'test_ospf_sr_te_topo1',
          'message' => "E   AssertionError: rt1 don't has entry 1111 but is was expected\n    assert False",
          'execution_time' => 30
        }
      end

      before do
        ci_job
        update_status.update
      end

      it 'must creates a topotest_failure' do
        expect(failure.to_h).to eq(failure_info)
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> success' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'success' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end

    context 'when Ci Job TopoTest Part 0 update from in_progress -> invalid' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:ci_jobs) { create_list(:ci_job, 5, check_suite: ci_job.check_suite) }
      let(:status) { 'success' }

      before do
        ci_jobs
      end

      it 'must returns success' do
        expect(update_status.update).to eq([200, 'Success'])
        ci_jobs.each { |job| expect(job.reload.status).not_to eq('skipped') }
      end
    end

    context 'when look for errors in Bamboo because it was not possible to read from the xml' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'in_progress') }
      let(:status) { 'failure' }
      let(:suite) { 'ospfv3_basic_functionality.test_ospfv3_ecmp' }

      let(:payload) do
        {
          'status' => status,
          'bamboo_ref' => ci_job.job_ref,
          'output' => {
            'title' => 'Failed test',
            'summary' => "There was some test that failed, but I couldn't find the log."
          },
          'failures' => []
        }
      end

      let(:expected_message) do
        "AssertionError: Testcase test_ospfv3_ecmp_tc16_p0 : Failed \n
Error: Nexthop {'fe80::48c7:9ff:fe98:52c8'} is Missing for route 2::1/128 in RIB of router r1\n
\nassert \"Nexthop {'fe80::48c7:9ff:fe98:52c8'} is Missing for route 2::1/128 in RIB of router r1\\n\" is True
\nE   AssertionError: Testcase test_ospfv3_ecmp_tc16_p0 : Failed \n
Error: Nexthop {'fe80::48c7:9ff:fe98:52c8'} is Missing for route 2::1/128 in RIB of router r1\n
\n    assert \"Nexthop {'fe80::48c7:9ff:fe98:52c8'} is Missing for route 2::1/128 in RIB of router r1\\n\" is True"
      end

      let(:fake_output) do
        {
          'expand' => 'changes,testResults,metadata,plan,artifacts,comments,labels,jiraIssues,variables,logFiles',
          'testResults' =>
            { 'expand' => "allTests,successfulTests,failedTests,newFailedTests,
existingFailedTests,fixedTests,quarantinedTests,skippedTests",
              'all' => 273,
              'successful' => 272,
              'failed' => 1,
              'newFailed' => 1,
              'existingFailed' => 0,
              'fixed' => 0,
              'quarantined' => 0,
              'skipped' => 27,
              'allTests' => { 'size' => 273, 'start-index' => 0, 'max-result' => 273 },
              'successfulTests' => { 'size' => 272, 'start-index' => 0, 'max-result' => 272 },
              'failedTests' =>
                { 'size' => 1,
                  'expand' => 'testResult',
                  'testResult' =>
                    [{ 'testCaseId' => 157_699_933,
                       'expand' => 'errors',
                       'className' => suite,
                       'methodName' => 'test_ospfv3_ecmp_tc16_p0',
                       'status' => 'failed',
                       'duration' => 128_517,
                       'durationInSeconds' => 128,
                       'errors' =>
                         { 'size' => 1,
                           'error' =>
                             [{ 'message' => expected_message }],
                           'start-index' => 0,
                           'max-result' => 1 } }],
                  'start-index' => 0,
                  'max-result' => 1 },
              'newFailedTests' => { 'size' => 1, 'start-index' => 0, 'max-result' => 1 },
              'existingFailedTests' => { 'size' => 0, 'start-index' => 0, 'max-result' => 0 },
              'fixedTests' => { 'size' => 0, 'start-index' => 0, 'max-result' => 0 },
              'quarantinedTests' => { 'size' => 0, 'start-index' => 0, 'max-result' => 0 },
              'skippedTests' => { 'size' => 27, 'start-index' => 0, 'max-result' => 27 } }
        }
      end

      let(:expected_output) do
        {
          title: 'Failed test',
          summary: expected_message
        }
      end

      let(:expected_topotest_failure) do
        {
          'suite' => suite,
          'case' => 'test_ospfv3_ecmp_tc16_p0',
          'message' => expected_message,
          'execution_time' => 128
        }
      end

      context 'when updated a test that failed and it has no error output' do
        before do
          allow(CiJob).to receive(:find_by).and_return(ci_job)
          allow(ci_job).to receive(:failure)
          allow(BambooCi::Result).to receive(:fetch).and_return(fake_output)

          update_status.update
        end

        it 'must update the output' do
          expect(ci_job).to have_received(:failure).with(fake_github_check, expected_output)
        end

        it 'must create TopoTestFailure' do
          expect(TopotestFailure.all.size).to eq(1)
          expect(TopotestFailure.last.to_h).to eq(expected_topotest_failure)
        end
      end

      context 'when updated a test that failed and unabled to fetch results' do
        let(:fake_output) do
          {
            'testResults' => {
              'failedTests' => nil
            }
          }
        end
        before do
          allow(CiJob).to receive(:find_by).and_return(ci_job)
          allow(ci_job).to receive(:failure)
          allow(BambooCi::Result).to receive(:fetch).and_return(fake_output)

          update_status.update
        end

        it 'must not create TopoTestFailure' do
          expect(TopotestFailure.all.size).to eq(0)
        end
      end

      context 'When bamboo returns an empty hash' do
        let(:expected_output) do
          {
            title: 'Failed test',
            summary: "There was some test that failed, but I couldn't find the log."
          }
        end

        before do
          allow(CiJob).to receive(:find_by).and_return(ci_job)
          allow(ci_job).to receive(:failure)
          allow(BambooCi::Result).to receive(:fetch).and_return({})

          update_status.update
        end

        it 'must maintain the same output' do
          expect(ci_job).to have_received(:failure).with(fake_github_check, expected_output)
        end

        it 'must not create a TopoTestFailure' do
          expect(TopotestFailure.all.size).to eq(0)
        end
      end
    end

    describe 'Slack notification' do
      context 'when update CI Job to success' do
        let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress') }
        let(:subscription) { create(:pull_request_subscription, target: ci_job.check_suite.pull_request.github_pr_id) }
        let(:status) { 'success' }

        before do
          subscription

          stub_request(:post, "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user")
            .to_return(status: 200, body: '', headers: {})
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end
      end

      context 'when update CI Job to success but it is an old execution' do
        let(:pull_request) { create(:pull_request) }
        let(:check_suite) { create(:check_suite, pull_request: pull_request) }
        let(:check_suite_new) { create(:check_suite, pull_request: pull_request) }
        let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress', check_suite: check_suite) }
        let(:ci_job_new) { create(:ci_job, name: 'AMD Build', status: 'in_progress', check_suite: check_suite_new) }
        let(:subscription) { create(:pull_request_subscription, target: ci_job.check_suite.pull_request.github_pr_id) }
        let(:status) { 'success' }

        before do
          check_suite
          ci_job_new
          subscription

          stub_request(:post, "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user")
            .to_return(status: 200, body: '', headers: {})
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end
      end

      context 'when update CI Job to failure' do
        let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress') }
        let(:subscription) { create(:pull_request_subscription, target: ci_job.check_suite.pull_request.github_pr_id) }
        let(:status) { 'failure' }

        before do
          subscription

          stub_request(:post, "#{GitHubApp::Configuration.instance.config['slack_bot_url']}/github/user")
            .to_return(status: 200, body: '', headers: {})
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end
      end
    end

    describe 'Build Stage' do
      let(:payload) do
        {
          'status' => status,
          'bamboo_ref' => ci_job.job_ref
        }
      end

      context 'when Ci Job AMD Build update from queued -> in_progress' do
        let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'queued') }
        let(:status) { 'in_progress' }

        before do
          ci_job
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must update parent stage' do
          update_status.update
          expect(ci_job.parent_stage.reload.status).to eq(status)
        end
      end

      context 'when Ci Job TopoTest Part 0 update from queued -> in_progress' do
        let(:ci_job) { create(:ci_job, :test, name: 'TopoTest Part 0', status: 'queued') }
        let(:status) { 'in_progress' }

        before do
          ci_job
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must update parent stage' do
          update_status.update
          expect(ci_job.parent_stage.reload.status).to eq('in_progress')
        end
      end

      context 'when Ci Job TopoTest Part 0 update from in_progress -> success' do
        let(:ci_job) { create(:ci_job, :test, name: 'TopoTest Part 0', status: 'in_progress') }
        let(:status) { 'success' }

        before do
          ci_job
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must change Tests to success' do
          update_status.update
          expect(ci_job.parent_stage.reload.status).to eq(status)
        end
      end

      context 'when Ci Job TopoTest Part 0 update from in_progress -> failure' do
        let(:ci_job) { create(:ci_job, :test, :topotest_failure, name: 'TopoTest Part 0', status: 'in_progress') }
        let(:status) { 'failure' }

        let(:test_failure) do
          create(:ci_job,
                 :topotest_failure,
                 name: 'TopoTest Part 1',
                 status: 'failure',
                 check_suite: ci_job.check_suite, parent_stage: ci_job.parent_stage)
        end

        before do
          ci_job
          test_failure
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must change Tests to success' do
          update_status.update
          expect(test_failure.parent_stage.reload.status).to eq(status)
        end
      end

      context 'when Ci Job AMD Build update from in_progress -> failure' do
        let(:ci_job) { create(:ci_job, :build, name: 'AMD Build', status: 'in_progress') }
        let(:arm) { create(:ci_job, :build, name: 'ARM8 Build', status: 'failure') }
        let(:status) { 'failure' }
        let(:stages) { ParentStage.where(check_suite: ci_job.check_suite) }

        let(:test) do
          create(:ci_job, :test, name: 'TopoTest Part 0', status: 'in_progress', check_suite: ci_job.check_suite)
        end

        let(:url) do
          "https://127.0.0.1/rest/api/latest/result/#{ci_job.job_ref}?" \
            'expand=testResults.failedTests.testResult.errors,artifacts'
        end

        let(:response) do
          {
            'artifacts' => {
              'artifact' => [
                {
                  'name' => 'ErrorLog',
                  'link' => {
                    'href' => 'https://127.0.0.1/ok.log'
                  }
                }
              ]
            }
          }
        end

        before do
          stub_request(:get, url)
            .with(
              headers: {
                'Accept' => %w[*/* application/json],
                'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
                'Authorization' => 'Basic Og==',
                'Host' => '127.0.0.1',
                'User-Agent' => 'Ruby'
              }
            )
            .to_return(status: 200, body: response.to_json, headers: {})

          stub_request(:get, 'https://127.0.0.1/ok.log')
            .with(
              headers: {
                'Accept' => '*/*',
                'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
                'Authorization' => 'Basic Og==',
                'Host' => '127.0.0.1',
                'User-Agent' => 'Ruby'
              }
            )
            .to_return(status: 200, body: 'make: *** [all] Error 2', headers: {})

          ci_job
          test
          arm
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must update parent stage' do
          update_status.update
          expect(ci_job.parent_stage.reload.status).to eq(status)
        end

        it 'must keep Tests skipped' do
          update_status.update
          expect(stages.last.reload.status).to eq('cancelled')
        end
      end

      context 'when Ci Job AMD Build update from in_progress -> success' do
        let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress') }
        let(:test) { create(:ci_job, name: 'TopoTest Part 0', status: 'queued', check_suite: ci_job.check_suite) }
        let(:status) { 'success' }

        before do
          ci_job
          test
        end

        it 'must returns success' do
          expect(update_status.update).to eq([200, 'Success'])
        end

        it 'must update Build Job' do
          update_status.update
          expect(ci_job.parent_stage.reload.status).to eq(status)
        end

        it 'must keep Tests enqueued' do
          update_status.update
          expect(test.parent_stage.reload.status).to eq('in_progress')
        end
      end
    end

    describe '#current_execution' do
      let(:pull_request) { create(:pull_request) }
      let(:check_suite1) { create(:check_suite, pull_request: pull_request) }
      let(:check_suite2) { create(:check_suite, pull_request: pull_request) }
      let(:ci_job) { create(:ci_job, name: 'AMD Build', status: 'in_progress', check_suite: check_suite1) }
      let(:ci_job_new) { create(:ci_job, name: 'AMD Build', status: 'in_progress', check_suite: check_suite2) }

      context 'when old execution fails' do
        let(:status) { 'failure' }

        before do
          ci_job
          ci_job_new
        end

        it 'must not generate slack message' do
          update_status.update
          expect(ci_job.reload.status).to eq(status)
        end
      end

      context 'when old execution passes' do
        let(:status) { 'success' }

        before do
          ci_job
          ci_job_new
        end

        it 'must not generate slack message' do
          update_status.update
          expect(ci_job.reload.status).to eq(status)
        end
      end
    end
  end

  describe 'Checking invalid commands' do
    context 'when receives an empty payload' do
      let(:payload) { {} }

      it 'must returns error' do
        expect(update_status.update).to eq([404, 'CI JOB not found'])
      end
    end

    context 'when receives an invalid CI Job' do
      let(:payload) do
        {
          'status' => 'invalid',
          'bamboo_ref' => 12_345
        }
      end

      it 'must returns error' do
        expect(update_status.update).to eq([404, 'CI JOB not found'])
      end
    end

    context 'when a test sends an invalid status' do
      let(:ci_job) { create(:ci_job, name: 'TopoTest Part 0', status: 'queued') }
      let(:payload) do
        {
          'status' => 'failure',
          'bamboo_ref' => ci_job.job_ref
        }
      end

      it 'must returns not modified' do
        expect(update_status.update).to eq([304, 'Not Modified'])
      end
    end

    context 'when building image sends an invalid status' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Codde', status: 'in_progress') }
      let(:payload) do
        {
          'status' => 'queued',
          'bamboo_ref' => ci_job.job_ref,
          'output' => {
            'title' => 'Title',
            'summary' => 'Summary'
          }
        }
      end

      it 'must returns not modified' do
        expect(update_status.update).to eq([304, 'Not Modified'])
      end
    end
  end
end
