#  SPDX-License-Identifier: BSD-2-Clause
#
#  revert_retry_check_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe RevertRetryCheck do
  let(:fake_github_check) { instance_double(Github::Check, failure: true, create: double(id: 10)) }
  let(:output) { { title: 'Retry failed', summary: 'Bamboo did not restart the build.' } }

  before do
    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(SlackBot.instance).to receive(:stage_finished_notification)
  end

  describe '.sync' do
    context 'when the stage is still failure' do
      let(:stage) { create(:stage, status: :failure) }

      it 'sends the failure to GitHub' do
        described_class.sync('Stage', stage.id, output)

        expect(fake_github_check).to have_received(:failure).with(10, output)
      end
    end

    context 'when the job is still failure' do
      let(:ci_job) { create(:ci_job, status: :failure, check_ref: '5') }

      it 'sends the failure to GitHub' do
        described_class.sync('CiJob', ci_job.id, output)

        expect(fake_github_check).to have_received(:failure).with('5', output)
      end
    end

    context 'when a new retry already moved the check on' do
      let(:stage) { create(:stage, status: :queued) }

      it 'leaves GitHub as it is' do
        described_class.sync('Stage', stage.id, output)

        expect(fake_github_check).not_to have_received(:failure)
      end
    end

    context 'when the record is gone' do
      it 'does nothing' do
        described_class.sync('Stage', 0, output)

        expect(fake_github_check).not_to have_received(:failure)
      end
    end

    context 'when the class is not a check' do
      it 'does nothing' do
        described_class.sync('CheckSuite', 1, output)

        expect(fake_github_check).not_to have_received(:failure)
      end
    end
  end
end
