#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe PullRequest do
  context 'when create a new PR' do
    let(:pull_request) { create(:pull_request) }

    it 'must return true' do
      expect(pull_request.new?).to be_truthy
    end
  end

  context 'when create a new PR with Check Suite' do
    let(:pull_request) { create(:pull_request, :with_check_suite) }

    it 'must return true' do
      expect(pull_request.new?).to be_falsey
    end
  end

  context 'when create a new PR and check if check suite was finished' do
    let(:pull_request) { create(:pull_request) }

    it 'must return true' do
      expect(pull_request.finished?).to be_truthy
    end
  end

  context 'when create a new PR and check if check suite was finished' do
    let(:pull_request) { create(:pull_request, :with_check_suite) }

    it 'must return true' do
      expect(pull_request.finished?).to be_falsey
    end
  end
end
