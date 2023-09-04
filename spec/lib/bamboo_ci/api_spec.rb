#  SPDX-License-Identifier: BSD-2-Clause
#
#  api_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

class Dummy
  include BambooCi::Api

  def initialize
    @logger = Logger.new('/dev/null')
  end
end

describe BambooCi::Api do
  let(:dummy) { Dummy.new }

  before do
    allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })

    stub_request(http_method, url)
      .with(
        headers: {
          'Accept' => %w[*/* application/json],
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
          'Host' => '127.0.0.1',
          'User-Agent' => 'Ruby'
        }
      )
      .to_return(status: status, body: body.to_json, headers: {})

    allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })
  end

  context 'when call fetch_executions' do
    let(:http_method) { :get }
    let(:url) { "https://127.0.0.1/rest/api/latest/search/jobs/#{plan}" }
    let(:plan) { 'test' }
    let(:status) { 200 }

    let(:body) do
      {}
    end

    it 'must returns success' do
      expect(dummy.fetch_executions(plan)).to eq(body)
    end
  end

  context 'when call fetch_status' do
    let(:http_method) { :get }
    let(:url) { "https://127.0.0.1/rest/api/latest/result/#{id}?expand=stages.stage.results,artifacts" }
    let(:id) { 1 }
    let(:status) { 200 }

    let(:body) do
      {
        'status' => 'in progress'
      }
    end

    it 'must returns success' do
      expect(dummy.get_status(id)).to eq(body)
    end
  end

  context 'when call submit_pr_to_ci' do
    let(:http_method) { :post }
    let(:id) { 1 }
    let(:status) { 200 }
    let(:check_suite) { create(:check_suite) }

    let(:url) do
      "https://127.0.0.1/rest/api/latest/queue/#{check_suite.pull_request.plan}" \
        "#{custom_variables}#{ci_variables_parsed}"
    end

    let(:ci_variables_parsed) do
      ci_variables.map { |entry| "&bamboo.variable.github_#{entry[:name]}=#{entry[:value]}" }.join
    end

    let(:custom_variables) do
      "?customRevision=#{check_suite.merge_branch}" \
        "&bamboo.variable.github_repo=#{check_suite.pull_request.repository.gsub('/', '%2F')}" \
        "&bamboo.variable.github_pullreq=#{check_suite.pull_request.github_pr_id}" \
        "&bamboo.variable.github_branch=#{check_suite.merge_branch}" \
        "&bamboo.variable.github_merge_sha=#{check_suite.commit_sha_ref}" \
        "&bamboo.variable.github_base_sha=#{check_suite.base_sha_ref}"
    end

    let(:ci_variables) do
      [{ name: 'test', value: 10 }]
    end

    let(:body) do
      {
        'status' => 'in progress'
      }
    end

    it 'must returns success' do
      expect(dummy.submit_pr_to_ci(check_suite, ci_variables).code.to_i).to eq(status)
    end
  end

  context 'when call add_comment_to_ci' do
    let(:http_method) { :post }
    let(:key) { 1 }
    let(:status) { 200 }
    let(:check_suite) { create(:check_suite) }
    let(:url) { "https://127.0.0.1/rest/api/latest/result/#{key}/comment" }
    let(:comment) { 'Starting PR' }

    let(:body) do
      {
        'status' => 'in progress'
      }
    end

    it 'must returns success' do
      expect(dummy.add_comment_to_ci(key, comment).code.to_i).to eq(status)
    end
  end

  context 'when call delete_request' do
    let(:http_method) { :delete }
    let(:status) { 200 }
    let(:url) { 'https://127.0.0.1/rest/api/latest/result/comment' }

    let(:body) do
      {
        'status' => 'in progress'
      }
    end

    before do
      stub_request(http_method, url)
        .with(
          headers: {
            'Accept' => %w[*/*],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: status, body: body.to_json, headers: {})

      allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })
    end

    it 'must returns success' do
      expect(dummy.delete_request(URI(url)).code.to_i).to eq(status)
    end
  end

  context 'when call put_request' do
    let(:http_method) { :put }
    let(:status) { 200 }
    let(:url) { 'https://127.0.0.1/rest/api/latest/result/comment' }

    let(:body) do
      {
        'status' => 'in progress'
      }
    end

    before do
      stub_request(http_method, url)
        .with(
          headers: {
            'Accept' => %w[*/*],
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Authorization' => 'Basic dXNlcjpwYXNzd29yZA==',
            'Host' => '127.0.0.1',
            'User-Agent' => 'Ruby'
          }
        )
        .to_return(status: status, body: body.to_json, headers: {})

      allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] })
    end

    it 'must returns success' do
      expect(dummy.put_request(URI(url)).code.to_i).to eq(status)
    end
  end
end
