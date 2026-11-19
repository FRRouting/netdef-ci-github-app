#  SPDX-License-Identifier: BSD-2-Clause
#
#  open_checks_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::OpenChecks do
  let(:github) { instance_double(Github::Check, cancelled: true, create: double(id: 1)) }
  let(:check_suite) { create(:check_suite) }
  let(:running_stage) { create(:stage, :in_progress, check_suite: check_suite) }
  let(:finished_stage) { create(:stage, check_suite: check_suite, status: :success) }
  let!(:running_job) { create(:ci_job, :in_progress, check_suite: check_suite, stage: running_stage) }
  let!(:finished_job) { create(:ci_job, :success, check_suite: check_suite, stage: finished_stage) }

  before do
    allow(SlackBot.instance).to receive(:stage_finished_notification)
    allow(Github::Check).to receive(:new).and_return(github)
    described_class.cancel(check_suite)
  end

  it 'reports the cancellation on the commit of the stopped suite' do
    expect(Github::Check).to have_received(:new).with(check_suite)
  end

  it 'cancels the open jobs and stages' do
    expect(running_job.reload.status).to eq('cancelled')
    expect(running_stage.reload.status).to eq('cancelled')
  end

  it 'keeps the jobs and stages that already finished' do
    expect(finished_job.reload.status).to eq('success')
    expect(finished_stage.reload.status).to eq('success')
  end
end
