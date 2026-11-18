#  SPDX-License-Identifier: BSD-2-Clause
#
#  pending_jobs_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::Summary::PendingJobs do
  let(:stage) { create(:stage, :in_progress, :with_check_suite) }

  describe '.schedule' do
    let(:delayed) { double('delayed SyncPendingJobs', sync: true) }

    before { allow(SyncPendingJobs).to receive(:delay).and_return(delayed) }

    it 'enqueues the Bamboo sync of the stage' do
      described_class.schedule(stage, 'Github')

      expect(SyncPendingJobs).to have_received(:delay).with(queue: described_class::QUEUE)
      expect(delayed).to have_received(:sync).with(stage.id, 'Github')
    end

    context 'when a sync of the stage is already pending' do
      before { allow(DelayedJobLookup).to receive(:pending).and_return(double(exists?: true)) }

      it 'does not enqueue another one' do
        described_class.schedule(stage, 'Github')

        expect(SyncPendingJobs).not_to have_received(:delay)
      end
    end
  end

  describe '.sync_stage' do
    it 'does nothing for a stage that no longer exists' do
      expect(described_class.sync_stage(0, 'Github')).to be_nil
    end

    it 'does nothing for a stage with no open job' do
      allow(BambooCi::Result).to receive(:fetch)

      described_class.sync_stage(stage.id, 'Github')

      expect(BambooCi::Result).not_to have_received(:fetch)
    end
  end
end
