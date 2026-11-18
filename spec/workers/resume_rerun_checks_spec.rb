#  SPDX-License-Identifier: BSD-2-Clause
#
#  resume_rerun_checks_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe ResumeRerunChecks do
  let(:plan) { create(:plan) }
  let(:check_suite) { create(:check_suite) }
  let(:payload) { { 'sender' => { 'login' => 'user', 'id' => 1, 'type' => 'User' } } }
  let(:checks_resume) { instance_double(Github::ReRun::ChecksResume, resume: [201, 'Re-run GitHub checks resumed']) }

  before { allow(Github::ReRun::ChecksResume).to receive(:new).and_return(checks_resume) }

  describe '.run' do
    it 'returns 404 when the check suite is gone' do
      expect(described_class.run(payload, 0, plan.id)).to eq([404, 'Check Suite or Plan not found'])
      expect(Github::ReRun::ChecksResume).not_to have_received(:new)
    end

    it 'returns 404 when the plan is gone' do
      expect(described_class.run(payload, check_suite.id, 0)).to eq([404, 'Check Suite or Plan not found'])
    end

    it 'delegates the resume to Github::ReRun::ChecksResume' do
      expect(described_class.run(payload, check_suite.id, plan.id)).to eq([201, 'Re-run GitHub checks resumed'])

      expect(Github::ReRun::ChecksResume).to have_received(:new).with(payload)
      expect(checks_resume).to have_received(:resume).with(check_suite, plan)
    end
  end
end
