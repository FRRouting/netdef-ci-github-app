#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job_fetch_topotest_failures_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe CiJobFetchTopotestFailures do
  let(:ci_job) { create(:ci_job, retry: 1) }
  let(:failures) { [{ 'suite' => 's', 'case' => 'c', 'message' => 'm', 'execution_time' => 1 }] }
  let(:retrieve_error) { instance_double(Github::TopotestFailures::RetrieveError, retrieve: true, failures: failures) }

  before { allow(Github::TopotestFailures::RetrieveError).to receive(:new).and_return(retrieve_error) }

  describe '.update' do
    it 'stores the failures under the attempt that failed' do
      described_class.update(ci_job.id, 1, 1)

      expect(ci_job.topotest_failures.pluck(:attempt)).to eq([1])
    end

    context 'when a ci:retry already started the next attempt' do
      it 'does not read Bamboo, which only has the newer attempt' do
        create(:topotest_failure, ci_job: ci_job, attempt: 0)

        described_class.update(ci_job.id, 1, 0)

        expect(Github::TopotestFailures::RetrieveError).not_to have_received(:new)
        expect(ci_job.topotest_failures.count).to eq(1)
      end
    end

    context 'when a ci:retry starts the next attempt while Bamboo is read' do
      before do
        allow(retrieve_error).to receive(:retrieve) { ci_job.update(retry: 2) }
      end

      it 'discards what was read' do
        described_class.update(ci_job.id, 1, 1)

        expect(ci_job.topotest_failures).to be_empty
      end
    end

    it 'falls back to the current attempt for fetches scheduled without one' do
      described_class.update(ci_job.id, 1)

      expect(ci_job.topotest_failures.pluck(:attempt)).to eq([1])
    end

    context 'when Bamboo has no failures yet' do
      let(:failures) { [] }
      let(:delayed) { double('delayed', update: true) }

      before { allow(described_class).to receive(:delay).and_return(delayed) }

      it 'keeps the attempt when it tries again later' do
        described_class.update(ci_job.id, 1, 1)

        expect(delayed).to have_received(:update).with(ci_job.id, 2, 1)
      end
    end
  end
end
