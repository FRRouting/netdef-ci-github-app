#  SPDX-License-Identifier: BSD-2-Clause
#
#  user_info_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::UserInfo do
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_client) { Octokit::Client.new }
  let(:github_info) { { login: 'octocat', name: 'Octo Cat', email: 'octo@example.org', type: 'User' } }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:fetch_username).and_return(github_info)
  end

  context 'when called with a check suite' do
    let(:check_suite) { create(:check_suite) }

    it 'links the user to the check suite' do
      described_class.new(42, check_suite: check_suite)

      expect(GithubUser.find_by(github_id: 42).check_suites).to include(check_suite)
    end
  end

  context 'when the user already exists' do
    let(:check_suite) { create(:check_suite) }

    before { GithubUser.create(github_id: 44, github_login: 'old-login') }

    it 'updates the user instead of creating another one' do
      expect { described_class.new(44, check_suite: check_suite) }.not_to change(GithubUser, :count)
      expect(GithubUser.find_by(github_id: 44).github_login).to eq('octocat')
    end
  end

  context 'when called with a pull request only' do
    let(:pull_request) { create(:pull_request) }

    it 'links the user to the pull request' do
      described_class.new(43, pull_request: pull_request)

      expect(GithubUser.find_by(github_id: 43).pull_requests).to include(pull_request)
    end
  end
end
