# frozen_string_literal: true

describe BambooCi::PlanRun do
  let(:plan_run) { described_class.new(check_suite) }

  before do
    stub_request(:post, "https://127.0.0.1/rest/api/latest/queue/#{check_suite.pull_request.plan}?" \
                        "bamboo.variable.github_base_sha=#{check_suite.base_sha_ref}" \
                        "&bamboo.variable.github_branch=#{check_suite.merge_branch}&" \
                        "bamboo.variable.github_merge_sha=#{check_suite.commit_sha_ref}&" \
                        "bamboo.variable.github_pullreq=#{check_suite.work_branch}&" \
                        "bamboo.variable.github_repo=#{check_suite.pull_request.repository.gsub('/', '%2F')}&" \
                        "customRevision=#{check_suite.merge_branch}")
      .with(
        headers: {
          'Accept' => %w[*/* application/json],
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
          'Host' => '127.0.0.1',
          'User-Agent' => 'Ruby'
        }
      )
      .to_return(status: status, body: body, headers: {})
  end

  context 'when request a valid execution' do
    let(:check_suite) { create(:check_suite) }
    let(:status) { 200 }
    let(:body) { '{"buildResultKey": 1}' }
    let(:comment) do
      "<comment><content>GitHub Merge Request #{check_suite.pull_request.github_pr_id.split('/').last}\n" \
        "for GitHub Repo #{check_suite.pull_request.repository}, " \
        "branch #{check_suite.work_branch}\n\n" \
        "Request to merge from #{check_suite.pull_request.repository}\n" \
        "Merge Git Commit ID #{check_suite.commit_sha_ref} " \
        "on top of base Git Commit ID #{check_suite.base_sha_ref}</content></comment>"
    end

    before do
      stub_request(:post, 'https://127.0.0.1/rest/api/latest/result/1/comment')
        .with(
          body: comment,
          headers: {
            'Accept' => %w[*/* application/json],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic Z2l0aHViOkMzWHZpanQ5YlRkeXA0bWJeQ295',
            'Content-Type' => 'application/xml',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: 200, body: 'OK', headers: {})
    end

    it 'must returns success' do
      expect(plan_run.start_plan).to eq(200)
    end
  end

  describe 'Bamboo CI returns error from submit_pr_to_ci' do
    context 'when received a error 400' do
      let(:check_suite) { create(:check_suite) }
      let(:status) { 400 }
      let(:body) { '{"buildResultKey": 1}' }

      it 'must returns a error' do
        expect(plan_run.start_plan).to eq(400)
      end
    end

    context 'when reach max number of concurrent builds' do
      let(:check_suite) { create(:check_suite) }
      let(:status) { 400 }
      let(:body) { 'reached the maximum number of concurrent builds' }

      it 'must returns a error' do
        expect(plan_run.start_plan).to eq(429)
      end
    end

    context 'when HTTP POST Request failed' do
      let(:check_suite) { create(:check_suite) }
      let(:status) { 0 }
      let(:body) { '{}' }

      it 'must returns a error' do
        expect(plan_run.start_plan).to eq(418)
      end
    end

    context 'when HTTP POST returns 300' do
      let(:check_suite) { create(:check_suite) }
      let(:status) { 300 }
      let(:body) { '{}' }

      it 'must returns a error' do
        expect(plan_run.start_plan).to eq(300)
      end
    end
  end
end
