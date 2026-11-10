#  SPDX-License-Identifier: BSD-2-Clause
#
#  duplicate_request_guard_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::DuplicateRequestGuard do
  describe '.claim_retry?' do
    let(:check_suite) { create(:check_suite) }
    let(:other_check_suite) { create(:check_suite) }

    it 'accepts the first request and rejects a duplicate' do
      expect(described_class.claim_retry?(check_suite)).to be(true)
      expect(described_class.claim_retry?(check_suite)).to be(false)
      expect(check_suite.reload.retry_requested_at).not_to be_nil
    end

    it 'accepts a new request once the window has passed' do
      check_suite.update(retry_requested_at: (described_class::WINDOW + 1).seconds.ago)

      expect(described_class.claim_retry?(check_suite)).to be(true)
    end

    it 'does not block other check suites' do
      described_class.claim_retry?(check_suite)

      expect(described_class.claim_retry?(other_check_suite)).to be(true)
    end
  end

  describe '.release_retry' do
    let(:check_suite) { create(:check_suite) }

    it 'allows a new request right after a released claim' do
      described_class.claim_retry?(check_suite)
      described_class.release_retry(check_suite)

      expect(check_suite.reload.retry_requested_at).to be_nil
      expect(described_class.claim_retry?(check_suite)).to be(true)
    end
  end

  describe '.claim_rerun?' do
    let(:pull_request) { create(:pull_request) }

    it 'accepts the first request and rejects a duplicate' do
      expect(described_class.claim_rerun?(pull_request)).to be(true)
      expect(described_class.claim_rerun?(pull_request)).to be(false)
    end

    it 'accepts a new request once the window has passed' do
      pull_request.update(rerun_requested_at: (described_class::WINDOW + 1).seconds.ago)

      expect(described_class.claim_rerun?(pull_request)).to be(true)
    end
  end
end
