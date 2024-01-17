#  SPDX-License-Identifier: BSD-2-Clause
#
#  check_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Check do
  let(:check) { described_class.new(check_suite) }
  let(:check_suite) { create(:check_suite) }
  let(:fake_client) { Octokit::Client.new }

  before do
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
  end

  context 'when call pull_request_info' do
    let(:pr_id) { 1 }
    let(:repo) { 'test' }
    let(:pr_info) { {} }

    before do
      allow(fake_client).to receive(:pull_request).with(repo, pr_id).and_return(pr_info)
    end

    it 'must returns pull request info' do
      expect(check.pull_request_info(pr_id, repo)).to eq(pr_info)
    end
  end

  context 'when call fetch_pull_request_commits' do
    let(:pr_id) { 1 }
    let(:repo) { 'test' }
    let(:page) { 1 }
    let(:pr_info) { {} }

    before do
      allow(fake_client).to receive(:pull_request_commits)
        .with(repo, pr_id, per_page: 100, page: page)
        .and_return(pr_info)
    end

    it 'must returns pull request info' do
      expect(check.fetch_pull_request_commits(pr_id, repo, page)).to eq(pr_info)
    end
  end

  context 'when call add_comment' do
    let(:pr_id) { 1 }
    let(:repo) { 'test' }
    let(:comment) { Faker::Quote.yoda }
    let(:pr_info) { { comment: comment } }

    before do
      allow(fake_client).to receive(:add_comment).with(repo, pr_id, comment).and_return(pr_info)
    end

    it 'must returns pull request info' do
      expect(check.add_comment(pr_id, comment, repo)).to eq(pr_info)
    end
  end

  context 'when call comment_reaction_thumb_up' do
    let(:pr_id) { 1 }
    let(:repo) { 'test' }
    let(:comment_id) { 1 }
    let(:pr_info) { { comment_id: comment_id } }

    before do
      allow(fake_client).to receive(:create_issue_comment_reaction).with(repo, comment_id, '+1').and_return(pr_info)
    end

    it 'must returns pull request info' do
      expect(check.comment_reaction_thumb_up(repo, comment_id)).to eq(pr_info)
    end
  end

  context 'when call create' do
    let(:pr_id) { 1 }
    let(:name) { 'test' }
    let(:pr_info) { { name: name } }

    before do
      allow(fake_client).to receive(:create_check_run)
        .with(check_suite.pull_request.repository, name,
              check_suite.commit_sha_ref, accept: 'application/vnd.github+json')
        .and_return(pr_info)
    end

    it 'must returns success' do
      expect(check.create(name)).to eq(pr_info)
    end
  end

  context 'when call queued' do
    let(:id) { 1 }
    let(:status) { 'queued' }
    let(:pr_info) { { status: status } }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                accept: 'application/vnd.github+json'
              })
        .and_return(pr_info)
    end

    it 'must returns success' do
      expect(check.queued(id)).to eq(pr_info)
    end
  end

  context 'when call in_progress' do
    let(:id) { 1 }
    let(:status) { 'in_progress' }
    let(:pr_info) { { status: status } }
    let(:output) { { title: 'Title', summary: 'Summary' } }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                output: output,
                accept: 'application/vnd.github+json'
              })
        .and_return(pr_info)
    end

    it 'must returns success' do
      expect(check.in_progress(id, output)).to eq(pr_info)
    end
  end

  context 'when call cancelled' do
    let(:id) { 1 }
    let(:status) { 'completed' }
    let(:conclusion) { 'cancelled' }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                conclusion: conclusion,
                accept: 'application/vnd.github+json'
              })
        .and_return({})
    end

    it 'must returns success' do
      expect(check.cancelled(id)).to eq({})
    end
  end

  context 'when call success' do
    let(:id) { 1 }
    let(:status) { 'completed' }
    let(:conclusion) { 'success' }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                conclusion: conclusion,
                accept: 'application/vnd.github+json'
              })
        .and_return({})
    end

    it 'must returns success' do
      expect(check.success(id)).to eq({})
    end
  end

  context 'when call success but check_ref is null' do
    let(:id) { nil }
    let(:status) { 'completed' }
    let(:conclusion) { 'success' }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                conclusion: conclusion,
                accept: 'application/vnd.github+json'
              })
        .and_return(true)
    end

    it 'must returns success' do
      expect(check.success(id)).to be_nil
    end
  end

  context 'when call failure' do
    let(:id) { 1 }
    let(:status) { 'completed' }
    let(:conclusion) { 'failure' }
    let(:output) { { title: 'Title', summary: 'Summary' } }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                conclusion: conclusion,
                output: output,
                accept: 'application/vnd.github+json'
              })
        .and_return({})
    end

    it 'must returns success' do
      expect(check.failure(id, output)).to eq({})
    end
  end

  context 'when call skipped' do
    let(:id) { 1 }
    let(:status) { 'completed' }
    let(:conclusion) { 'skipped' }

    before do
      allow(fake_client).to receive(:update_check_run)
        .with(check_suite.pull_request.repository,
              id,
              {
                status: status,
                conclusion: conclusion,
                accept: 'application/vnd.github+json'
              })
        .and_return({})
    end

    it 'must returns success' do
      expect(check.skipped(id)).to eq({})
    end
  end

  context 'when call get_check_run' do
    let(:id) { 1 }

    before do
      allow(fake_client).to receive(:check_run).and_return({})
    end

    it 'must returns success' do
      expect(check.get_check_run(id)).to eq({})
    end
  end

  context 'when call fetch_username' do
    let(:id) { 1 }

    before do
      allow(fake_client).to receive(:user).and_return({})
    end

    it 'must returns success' do
      expect(check.fetch_username(id)).to eq({})
    end
  end

  context 'when call fetch_username and raise' do
    let(:id) { 1 }

    before do
      allow(fake_client).to receive(:user).and_raise
    end

    it 'must returns success' do
      expect(check.fetch_username(id)).to be_falsey
    end
  end

  context 'when call signature' do
    it 'must returns success' do
      expect(check.signature).to eq(GitHubApp::Configuration.instance.config.dig('auth_signature', 'password'))
    end
  end

  describe '#installation_id' do
    context 'when find_app_installations returns error' do
      before do
        allow(fake_client).to receive(:find_app_installations).and_return([['', 'Missing']])
      end

      it 'must returns raise' do
        expect { check.installation_id }.to raise_error(StandardError)
      end
    end

    context 'when find_app_installations and is a empty array' do
      before do
        allow(fake_client).to receive(:find_app_installations).and_return([])
      end

      it 'must returns raise' do
        expect { check.installation_id }.to raise_error(StandardError)
      end
    end

    context 'when find_app_installations and last element does not exist' do
      before do
        allow(fake_client).to receive(:find_app_installations).and_return([['', nil]])
      end

      it 'must returns raise' do
        expect { check.installation_id }.to raise_error(StandardError)
      end
    end

    context 'when authenticate receive zero' do
      before do
        allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 0 }])
      end

      it 'must returns raise' do
        expect { check.installation_id }.to raise_error(StandardError, 'Github Authentication Failed')
      end
    end
  end
end
