# frozen_string_literal: true

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
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => "CI:rerun #{check_suite.commit_sha_ref}" },
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

        allow(BambooCi::PlanRun).to receive(:new).and_return(fake_plan_run)
        allow(fake_plan_run).to receive(:start_plan).and_return(200)
        allow(fake_plan_run).to receive(:bamboo_reference).and_return('UNIT-TEST-1')

        allow(BambooCi::StopPlan).to receive(:stop)
        allow(BambooCi::RunningPlan).to receive(:fetch).with(fake_plan_run.bamboo_reference).and_return(ci_jobs)
      end

      it 'must returns success' do
        expect(rerun.start).to eq([201, 'Starting re-run'])
        expect(check_suites.size).to eq(2)
      end
    end

    context 'when you receive an unregistered SHA' do
      let(:check_suite) { create(:check_suite, :with_running_ci_jobs) }
      let(:ci_jobs) { [{ name: 'First Test', job_ref: 'UNIT-TEST-FIRST-1' }] }
      let(:payload) do
        {
          'action' => 'created',
          'comment' => { 'body' => 'CI:rerun 000000' },
          'repository' => { 'full_name' => check_suite.pull_request.repository },
          'issue' => { 'number' => check_suite.pull_request.github_pr_id }
        }
      end

      before do
        allow(Octokit::Client).to receive(:new).and_return(fake_client)
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
        allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

        allow(Github::Check).to receive(:new).and_return(fake_github_check)
        allow(fake_github_check)
          .to receive(:add_comment).with(check_suite.pull_request.github_pr_id,
                                         'SHA256 000000 not found',
                                         check_suite.pull_request.repository)
      end

      it 'must returns error' do
        expect(rerun.start).to eq([404, 'Command not found'])
      end
    end
  end
end
