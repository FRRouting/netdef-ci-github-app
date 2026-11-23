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

  describe '.schedule_confirm' do
    let(:job) { create(:ci_job, :queued, stage: stage, check_suite: stage.check_suite) }
    let(:delayed) { double('delayed SyncPendingJobs', confirm: true) }

    before { allow(SyncPendingJobs).to receive(:delay).and_return(delayed) }

    it 'enqueues the first read right away' do
      described_class.schedule_confirm(job, 'Github')

      expect(SyncPendingJobs).to have_received(:delay)
        .with(run_at: be_within(5.seconds).of(Time.now.utc), queue: described_class::QUEUE)
      expect(delayed).to have_received(:confirm).with(job.id, 'Github', 1)
    end

    it 'does not enqueue a second confirmation for the same hook' do
      allow(DelayedJobLookup).to receive(:pending).and_return(double(exists?: true))

      described_class.schedule_confirm(job, 'Github')

      expect(SyncPendingJobs).not_to have_received(:delay)
    end
  end

  describe '.confirm_job' do
    let(:job) do
      create(:ci_job, :queued, stage: stage, check_suite: stage.check_suite, retry: retry_count)
    end
    let(:retry_count) { 0 }
    let(:requeued_at) { Time.now }
    let(:delayed) { double('delayed SyncPendingJobs', confirm: true) }
    let(:summary) { instance_double(Github::Build::Summary, build_summary: true) }
    let(:github) { instance_double(Github::Check, success: true, failure: true) }

    before do
      AuditStatus.create(auditable: job, status: :queued, agent: 'Github', created_at: requeued_at)
      allow(Github::Check).to receive(:new).and_return(github)
      allow(SyncPendingJobs).to receive(:delay).and_return(delayed)
      allow(Github::Build::Summary).to receive(:new).and_return(summary)
      allow(SlackBot.instance).to receive(:stage_finished_notification)
      allow(CiJobFetchTopotestFailures).to receive(:delay).and_return(double(update: true))
    end

    def bamboo_results(*results)
      allow(BambooCi::Result).to receive(:fetch).with(job.job_ref, expand: '').and_return(*results)
    end

    def result(state, life_cycle: 'Finished', completed: Time.now)
      { 'state' => state, 'lifeCycleState' => life_cycle, 'buildCompletedTime' => completed&.iso8601(3) }
    end

    it 'reads Bamboo again later while the result is not finished, then saves it' do
      bamboo_results(result('Unknown', life_cycle: 'InProgress'), result('Successful'))

      described_class.confirm_job(job.id, 'Github', 1)

      expect(job.reload.status).to eq('queued')
      expect(delayed).to have_received(:confirm).with(job.id, 'Github', 2)

      described_class.confirm_job(job.id, 'Github', 2)

      expect(job.reload.status).to eq('success')
      expect(delayed).to have_received(:confirm).once
    end

    it 'stops after the last attempt' do
      bamboo_results(result('Unknown', life_cycle: 'InProgress'))

      described_class.confirm_job(job.id, 'Github', described_class::CONFIRM_ATTEMPTS)

      expect(job.reload.status).to eq('queued')
      expect(SyncPendingJobs).not_to have_received(:delay)
    end

    it 'does nothing for a job that is already finished' do
      job.update(status: :success)
      allow(BambooCi::Result).to receive(:fetch)

      described_class.confirm_job(job.id, 'Github', 1)

      expect(BambooCi::Result).not_to have_received(:fetch)
      expect(SyncPendingJobs).not_to have_received(:delay)
    end

    it 'does nothing for a job that no longer exists' do
      expect(described_class.confirm_job(0, 'Github', 1)).to be_nil
    end

    context 'when a retry re-queued the job' do
      let(:retry_count) { 1 }

      it 'keeps waiting past the failure of the previous attempt and takes the new one' do
        bamboo_results(result('Failed', completed: requeued_at - 600),
                       result('Successful', completed: requeued_at + 600))

        described_class.confirm_job(job.id, 'Github', 1)

        expect(job.reload.status).to eq('queued')
        expect(delayed).to have_received(:confirm).with(job.id, 'Github', 2)

        described_class.confirm_job(job.id, 'Github', 2)

        expect(job.reload.status).to eq('success')
      end
    end
  end

  describe '#sync' do
    let(:github) { instance_double(Github::Check, success: true, failure: true) }
    let(:job) { create(:ci_job, :in_progress, stage: stage, check_suite: stage.check_suite, retry: retry_count) }
    let(:retry_count) { 0 }
    let(:requeued_at) { Time.now }
    let(:fetch_failures) { double('delayed CiJobFetchTopotestFailures', update: true) }

    before do
      AuditStatus.create(auditable: job, status: :queued, agent: 'Github', created_at: requeued_at)
      allow(CiJobFetchTopotestFailures).to receive(:delay).and_return(fetch_failures)
      allow(SlackBot.instance).to receive(:stage_finished_notification)
    end

    def bamboo_result(state, life_cycle: 'Finished', completed: Time.now)
      result = { 'state' => state, 'lifeCycleState' => life_cycle, 'buildCompletedTime' => completed&.iso8601(3) }
      allow(BambooCi::Result).to receive(:fetch).with(job.job_ref, expand: '').and_return(result)
    end

    def sync
      described_class.new(github, 'WatchDog').sync(stage)
    end

    it 'saves the result Bamboo reports for the job' do
      bamboo_result('Successful')

      sync

      expect(job.reload.status).to eq('success')
    end

    it 'keeps the job while Bamboo has not finished it' do
      bamboo_result('Unknown', life_cycle: 'InProgress')

      sync

      expect(job.reload.status).to eq('in_progress')
    end

    context 'when a retry re-queued the job' do
      let(:retry_count) { 1 }

      it 'ignores the failure of the previous attempt' do
        bamboo_result('Failed', completed: requeued_at - 600)

        sync

        expect(job.reload.status).to eq('in_progress')
        expect(CiJobFetchTopotestFailures).not_to have_received(:delay)
      end

      it 'ignores a result without its completion time' do
        bamboo_result('Failed', completed: nil)

        sync

        expect(job.reload.status).to eq('in_progress')
      end

      it 'saves the failure of the new attempt' do
        bamboo_result('Failed', completed: requeued_at + 600)

        sync

        expect(job.reload.status).to eq('failure')
        expect(fetch_failures).to have_received(:update).with(job.id, 1, 1)
      end
    end
  end
end
