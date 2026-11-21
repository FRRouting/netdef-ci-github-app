#  SPDX-License-Identifier: BSD-2-Clause
#
#  summary_refresh_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::SummaryRefresh do
  let(:pull_request) { create(:pull_request, github_pr_id: 24_358) }
  let(:check_suite) { create(:check_suite, pull_request: pull_request, bamboo_ci_ref: 'PLAN-12') }
  let(:ci_job) { create(:ci_job, check_suite: check_suite) }

  def status_job(bamboo_ref, queue: '8')
    Delayed::Job.create!(
      queue: queue,
      handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'CiJobStatus'\n" \
               "method_name: :update\nargs:\n- #{bamboo_ref}\n- 1\n"
    )
  end

  describe '.schedule' do
    let(:delayed) { double(update: true) }

    before { allow(CiJobStatus).to receive(:delay).and_return(delayed) }

    it 'replaces the pending refresh of the same execution only' do
      status_job('PLAN-12')
      other = status_job('PLAN-123')

      described_class.schedule(ci_job)

      expect(Delayed::Job.all).to contain_exactly(other)
      expect(CiJobStatus).to have_received(:delay).with(hash_including(queue: 8))
      expect(delayed).to have_received(:update).with('PLAN-12', ci_job.id)
    end
  end

  describe '.queue_for' do
    it 'uses the last digit of a PR number stored as a string' do
      allow(check_suite.pull_request).to receive(:github_pr_id).and_return('24357')

      expect(described_class.queue_for(check_suite)).to eq(7)
    end
  end
end
