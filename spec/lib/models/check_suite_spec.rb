#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe CheckSuite do
  context '#execution_started?' do
    let(:check_suite) { create(:check_suite) }
    let(:check_suite_running) { create(:check_suite, :with_in_progress) }

    it 'returns true when there are less than 2 jobs in progress' do
      expect(check_suite.execution_started?).to be_truthy
    end

    it 'returns false' do
      expect(check_suite_running.execution_started?).to be_falsey
    end
  end

  context '#last_job_updated_at_timer?' do
    let(:ci_job) { create(:ci_job, updated_at: nil) }
    let(:check_suite) { create(:check_suite, ci_jobs: [ci_job]) }
    let(:check_suite_running) { create(:check_suite, :with_in_progress) }

    it 'returns false' do
      expect(check_suite_running.last_job_updated_at_timer).not_to be_nil
    end
  end
end
