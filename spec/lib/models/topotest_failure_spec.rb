#  SPDX-License-Identifier: BSD-2-Clause
#
#  topotest_failure_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe TopotestFailure do
  describe '.replace_for' do
    let(:ci_job) { create(:ci_job) }
    let(:other_job) { create(:ci_job) }
    let(:failures) do
      [
        { 'suite' => 'suite_a', 'case' => 'case_a', 'message' => 'boom', 'execution_time' => 10 },
        { 'suite' => 'suite_b', 'case' => 'case_b', 'message' => 'bang', 'execution_time' => 20 }
      ]
    end

    before { create(:topotest_failure, ci_job: other_job) }

    it 'does not duplicate failures reported twice' do
      described_class.replace_for(ci_job, failures)
      described_class.replace_for(ci_job, failures)

      expect(ci_job.topotest_failures.map(&:to_h)).to match_array(failures)
    end

    it 'keeps the failures of other jobs' do
      described_class.replace_for(ci_job, failures)

      expect(other_job.topotest_failures.count).to eq(1)
    end
  end
end
