#  SPDX-License-Identifier: BSD-2-Clause
#
#  jobs_without_webhook_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::JobsWithoutWebhook do
  let(:check_suite) { create(:check_suite, bamboo_ci_ref: 'FRR-PULLREQ3-25201') }
  let(:stage) { create(:stage, :in_progress, check_suite: check_suite) }
  let(:job) { create(:ci_job, :without_webhook, stage: stage, check_suite: check_suite) }
  let(:github) { instance_double(Github::Check, in_progress: true, success: true, failure: true) }
  let(:delayed_poll) { double('delayed PollJobsWithoutWebhook', poll: true) }

  before do
    allow(Github::Check).to receive(:new).and_return(github)
    allow(PollJobsWithoutWebhook).to receive(:delay).and_return(delayed_poll)
    allow(Github::Build::SummaryRefresh).to receive(:schedule)
    allow(CiJobFetchTopotestFailures).to receive(:delay).and_return(double(update: true))
  end

  def bamboo_result(life_cycle, state = 'Unknown')
    result = { 'lifeCycleState' => life_cycle, 'state' => state, 'buildCompletedTime' => Time.now.iso8601(3) }
    allow(BambooCi::Result).to receive(:fetch).with(job.job_ref, expand: '').and_return(result)
  end

  def poll_job(handler_arg, locked_at: nil)
    Delayed::Job.create!(
      queue: described_class::QUEUE, locked_at: locked_at,
      handler: "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/class 'PollJobsWithoutWebhook'\n" \
               "method_name: :poll\nargs:\n- #{handler_arg}\n"
    )
  end

  describe '.schedule' do
    it 'enqueues a poll of the execution on its own queue' do
      job

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).to have_received(:delay).with(hash_including(queue: described_class::QUEUE))
      expect(delayed_poll).to have_received(:poll).with(check_suite.id)
    end

    it 'does nothing when every job has a webhook' do
      create(:ci_job, stage: stage, check_suite: check_suite)

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).not_to have_received(:delay)
    end

    it 'does nothing when the jobs without webhook are finished' do
      create(:ci_job, :without_webhook, :success, stage: stage, check_suite: check_suite)

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).not_to have_received(:delay)
    end

    it 'does nothing when the execution is closed' do
      job
      stage.update(status: :success)

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).not_to have_received(:delay)
    end

    it 'does nothing when a newer execution replaced this one' do
      job
      create(:check_suite, pull_request: check_suite.pull_request, plan: check_suite.plan,
                           bamboo_ci_ref: 'FRR-PULLREQ3-25202')

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).not_to have_received(:delay)
    end

    it 'keeps a single pending poll per execution' do
      job
      poll_job(check_suite.id)

      described_class.schedule(check_suite)

      expect(PollJobsWithoutWebhook).not_to have_received(:delay)
    end

    it 'does not count the poll that is running' do
      job
      poll_job(check_suite.id, locked_at: Time.now)

      described_class.schedule(check_suite)

      expect(delayed_poll).to have_received(:poll).with(check_suite.id)
    end
  end

  describe '.poll' do
    it 'does nothing for an execution that no longer exists' do
      expect(described_class.poll(0)).to be_nil
    end

    it 'marks a queued job in progress when Bamboo started it' do
      bamboo_result('InProgress')

      described_class.poll(check_suite.id)

      expect(job.reload.status).to eq('in_progress')
      expect(job.audit_statuses.last.agent).to eq(described_class::AGENT)
      expect(Github::Build::SummaryRefresh).to have_received(:schedule).with(job)
    end

    it 'saves the final result and schedules the next poll while the execution is open' do
      create(:ci_job, :without_webhook, stage: stage, check_suite: check_suite) # still queued in Bamboo
      allow(BambooCi::Result).to receive(:fetch).and_return({ 'lifeCycleState' => 'Queued' })
      bamboo_result('Finished', 'Successful')

      described_class.poll(check_suite.id)

      expect(job.reload.status).to eq('success')
      expect(delayed_poll).to have_received(:poll).with(check_suite.id)
    end

    it 'saves a failure' do
      bamboo_result('Finished', 'Failed')

      described_class.poll(check_suite.id)

      expect(job.reload.status).to eq('failure')
    end

    it 'does not touch a job already in progress while Bamboo still runs it' do
      job.update(status: :in_progress)
      bamboo_result('InProgress')

      described_class.poll(check_suite.id)

      expect(Github::Build::SummaryRefresh).not_to have_received(:schedule)
    end

    it 'skips a job Bamboo gives no result for' do
      job
      allow(BambooCi::Result).to receive(:fetch).and_return(nil)

      described_class.poll(check_suite.id)

      expect(job.reload.status).to eq('queued')
      expect(delayed_poll).to have_received(:poll).with(check_suite.id)
    end

    it 'keeps polling when one job fails' do
      job
      allow(BambooCi::Result).to receive(:fetch).and_raise(Timeout::Error)

      expect { described_class.poll(check_suite.id) }.not_to raise_error
      expect(delayed_poll).to have_received(:poll).with(check_suite.id)
    end
  end
end
