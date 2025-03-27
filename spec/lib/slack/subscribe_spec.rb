#  SPDX-License-Identifier: BSD-2-Clause
#
#  subscribe_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Slack::Subscribe do
  let(:subscribe) { described_class.new }
  let!(:pull_request) { create(:pull_request, :with_check_suite, id: 1) }

  context 'when subscribe with valid parameters' do
    let(:payload) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'all',
        'slack_user_id' => 'ABC'
      }
    end

    it 'must create a subscription' do
      expect(subscribe.call(payload)).to eq('Subscription created')
      expect(PullRequestSubscription.find_by(slack_user_id: payload['slack_user_id'])).not_to be_nil
    end
  end

  context 'when subscribe with valid parameters but failed to save' do
    let(:payload) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'all',
        'slack_user_id' => 'ABC'
      }
    end

    let(:fake_obj) { PullRequestSubscription.new }

    before do
      allow(PullRequestSubscription).to receive(:create).and_return(fake_obj)
      allow(fake_obj).to receive(:persisted?).and_return(false)
    end

    it 'must create a subscription' do
      expect(subscribe.call(payload)).to eq('Failed to subscribe')
      expect(PullRequestSubscription.find_by(slack_user_id: payload['slack_user_id'])).to be_nil
    end
  end

  context 'when update a subscription' do
    let(:create_request) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'all',
        'slack_user_id' => 'ABC'
      }
    end

    let(:update) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'errors',
        'slack_user_id' => 'ABC'
      }
    end

    let(:sub) { PullRequestSubscription.find_by(slack_user_id: update['slack_user_id']) }

    before do
      subscribe.call(create_request)
    end

    it 'must update a subscription' do
      expect(sub.reload.notification).to eq('all')
      expect(subscribe.call(update)).to eq('Subscription updated')
      expect(sub.reload.notification).to eq('errors')
    end
  end

  context 'when I try to unsubscribe without having subscribed' do
    let(:payload) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'off',
        'slack_user_id' => 'ABC'
      }
    end

    it 'must create a subscription' do
      expect(subscribe.call(payload)).to eq('Unsubscribed')
    end
  end

  context 'when I try to unsubscribe' do
    let(:unsub) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'off',
        'slack_user_id' => 'ABC'
      }
    end

    let(:sub) do
      {
        'rule' => 'notify',
        'target' => 1,
        'notification' => 'all',
        'slack_user_id' => 'ABC'
      }
    end

    before do
      subscribe.call(sub)
    end

    it 'must create a subscription' do
      expect(subscribe.call(unsub)).to eq('Unsubscribed')
      expect(PullRequestSubscription.find_by(slack_user_id: sub['slack_user_id'])).to be_nil
    end
  end

  describe 'Checking GitHub username' do
    let(:sub) do
      {
        'rule' => 'subscribe',
        'target' => 1,
        'notification' => 'all',
        'slack_user_id' => 'ABC'
      }
    end

    let(:fake_client) { Octokit::Client.new }
    let(:fake_github) { Github::Check.new(nil) }

    before do
      allow(File).to receive(:read).and_return('')
      allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))

      allow(Octokit::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
      allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

      allow(Github::Check).to receive(:new).and_return(fake_github)
      allow(fake_github).to receive(:authenticate_app)
    end

    context 'when you submit a username that does not exist' do
      before do
        allow(fake_github).to receive(:fetch_username).and_return(false)
      end

      it 'must returns an error' do
        expect(subscribe.call(sub)).to eq('Invalid GitHub username')
      end
    end

    context 'when you submit a username that does exist' do
      before do
        allow(fake_github).to receive(:fetch_username).and_return({})
      end

      it 'must returns success' do
        expect(subscribe.call(sub)).to eq('Subscription created')
      end
    end
  end
end
