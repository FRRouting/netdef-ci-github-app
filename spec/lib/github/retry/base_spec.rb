#  SPDX-License-Identifier: BSD-2-Clause
#
#  base_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Retry::Base do
  let(:check_suite) { create(:check_suite) }
  let(:retry_flow) do
    described_class.new({}).tap { |flow| flow.instance_variable_set(:@check_suite, check_suite) }
  end

  describe '#retry_once' do
    before do
      allow(retry_flow).to receive(:create_ci_jobs)
      allow(BambooCi::Retry).to receive(:restart).and_return(Net::HTTPOK.new('1.1', '200', 'OK'))
    end

    context 'when a step after the Bamboo restart fails' do
      before { allow(Github::Build::UnavailableJobs).to receive(:new).and_raise(RuntimeError, 'GitHub down') }

      it 'keeps the claim, so a duplicate does not restart the build again' do
        expect { retry_flow.send(:retry_once) }.to raise_error(RuntimeError, 'GitHub down')
        expect(check_suite.reload.retry_requested_at).not_to be_nil
      end
    end

    context 'when the restart is never reached' do
      before { allow(retry_flow).to receive(:create_ci_jobs).and_raise(RuntimeError, 'GitHub down') }

      it 'releases the claim, so the user can retry right away' do
        expect { retry_flow.send(:retry_once) }.to raise_error(RuntimeError, 'GitHub down')
        expect(check_suite.reload.retry_requested_at).to be_nil
        expect(BambooCi::Retry).not_to have_received(:restart)
      end
    end
  end
end
