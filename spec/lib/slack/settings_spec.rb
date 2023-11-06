#  SPDX-License-Identifier: BSD-2-Clause
#
#  settings_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Slack::Settings do
  let(:settings) { described_class.new }

  context 'when fetch settings but does not have any subscription' do
    let(:payload) { { 'slack_user_id' => 'ABC' } }

    it 'must return a message' do
      expect(settings.call(payload)).to eq("You don't have any subscription")
    end
  end

  context 'when fetch settings but does have an subscription' do
    let(:payload) { { 'slack_user_id' => 'ABC' } }

    before do
      create(:pull_request_subscription, slack_user_id: 'ABC')
      create(:pull_request_subscription, slack_user_id: 'ABC', rule: 'subscribe')
    end

    it 'must return a table' do
      expect(settings.call(payload)).not_to eq("You don't have any subscription")
      expect(settings.call(payload)).to include('Pull Request')
      expect(settings.call(payload)).to include('GitHub User')
    end
  end
end
