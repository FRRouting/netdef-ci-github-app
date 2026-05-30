#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request_commit_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Parsers::PullRequestCommit do
  let(:parser) { described_class.new(repo, pr_id) }
  let(:fake_client) { Octokit::Client.new }

  before do
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
  end

  describe '.find_by_sha' do
    let(:pr_id) { 1 }
    let(:repo) { 'test' }

    context 'when sha is nil' do
      let(:output) { [] }

      before do
        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 1)
          .and_return(output)
      end

      it 'must returns nil' do
        expect(parser.find_by_sha(nil)).to be_nil
      end
    end

    context 'when sha is valid, but invalid output' do
      let(:output) { [] }

      before do
        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 1)
          .and_return(output)
      end

      it 'must returns nil' do
        expect(parser.find_by_sha('abc')).to be_nil
      end
    end

    context 'when sha and output is valid' do
      let(:output) do
        [
          { sha: 'def' }
        ]
      end

      before do
        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 1)
          .and_return(output)

        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 2)
          .and_return([])
      end

      it 'must returns nil' do
        expect(parser.find_by_sha('abc')).to be_nil
      end
    end

    context 'when sha and output is valid and found sha' do
      let(:output) do
        [
          { sha: 'abc' }
        ]
      end

      before do
        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 1)
          .and_return(output)

        allow(fake_client).to receive(:pull_request_commits)
          .with(repo, pr_id, per_page: 100, page: 2)
          .and_return([])
      end

      it 'must returns nil' do
        expect(parser.find_by_sha('abc')).to eq(output.first)
      end
    end
  end
end
