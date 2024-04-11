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

  context 'when current execution is not the last check suite' do
    let(:pull_request) { create(:pull_request) }
    let(:check_suite1) { create(:check_suite, pull_request: pull_request) }
    let(:check_suite2) { create(:check_suite, pull_request: pull_request) }
    let(:check_suite3) { create(:check_suite, pull_request: pull_request) }

    before do
      check_suite1
      check_suite2
      check_suite3

      allow(pull_request).to receive(:check_suites).and_return([check_suite2, check_suite3, check_suite1])
    end

    it 'must return true' do
      expect(pull_request.current_execution?(check_suite3)).to be_truthy
    end
  end
end
