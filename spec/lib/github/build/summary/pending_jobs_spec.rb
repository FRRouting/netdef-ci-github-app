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

    it 'does nothing for a stage that is already closed' do
      closed = create(:stage, :success, :with_check_suite)
      create(:ci_job, :success, stage: closed, check_suite: closed.check_suite)
      allow(Github::Build::Summary).to receive(:new)

      described_class.sync_stage(closed.id, 'Github')

      expect(Github::Build::Summary).not_to have_received(:new)
    end

    context 'when the jobs were saved as finished but the stage summary failed before' do
      let(:job) { create(:ci_job, :success, stage: stage, check_suite: stage.check_suite) }
      let(:summary) { instance_double(Github::Build::Summary, build_summary: true) }

      before do
        allow(Github::Check).to receive(:new).and_return(instance_double(Github::Check))
        allow(BambooCi::Result).to receive(:fetch)
        allow(Github::Build::Summary).to receive(:new).and_return(summary)
      end

      it 'builds the stage summary again on the retry' do
        job

        described_class.sync_stage(stage.id, 'Github')

        expect(Github::Build::Summary).to have_received(:new).with(job, agent: 'Github')
        expect(BambooCi::Result).not_to have_received(:fetch)
      end
    end
  end
end
