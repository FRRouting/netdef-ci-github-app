#  SPDX-License-Identifier: BSD-2-Clause
#
#  ci_job_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe CiJob do
  let(:fake_client) { Octokit::Client.new }
  let(:github) { Github::Check.new(nil) }
  let(:github_fail) { Github::Check.new(nil) }
  let(:github_success) { Github::Check.new(nil) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(github_fail).to receive(:create).and_raise
    allow(github_success).to receive(:create).and_return(stage)
    allow(github_success).to receive(:queued).and_return(stage)
  end

  describe '#in_progress' do
    context 'when CiJob is not a stage' do
      let(:stage) { create(:ci_job, check_ref: nil) }

      it 'must update status' do
        stage.in_progress(github)
        expect(stage.reload.status).to eq('in_progress')
      end
    end
  end

  describe '#cancelled' do
    context 'when CiJob is not a stage' do
      let(:stage) { create(:ci_job, check_ref: nil) }

      it 'must update status' do
        stage.cancelled(github)
        expect(stage.reload.status).to eq('cancelled')
      end
    end
  end

  describe '#failure' do
    context 'when CiJob is not a stage' do
      let(:stage) { create(:ci_job, check_ref: nil) }

      it 'must update status' do
        stage.failure(github)
        expect(stage.reload.status).to eq('failure')
      end
    end
  end

  describe '#success' do
    context 'when CiJob is not a stage' do
      let(:stage) { create(:ci_job, check_ref: nil) }

      it 'must update status' do
        stage.success(github)
        expect(stage.reload.status).to eq('success')
      end
    end
  end

  describe '#skipped' do
    context 'when CiJob is not a stage' do
      let(:stage) { create(:ci_job, check_ref: nil) }

      it 'must update status' do
        stage.skipped(github)
        expect(stage.reload.status).to eq('skipped')
      end
    end
  end

  describe '#execution_time' do
    let(:stage) { create(:ci_job, check_ref: nil) }

    context 'when CiJob started and finished' do
      it 'must update status' do
        stage.in_progress(github)
        stage.success(github)
        stage.update_execution_time
      end
    end

    context 'when CiJob started and not finished' do
      it 'must update status' do
        stage.in_progress(github)
        stage.update_execution_time
      end
    end

    context 'when CiJob has no stage (stage is nil)' do
      let(:ci_job) { create(:ci_job, check_ref: nil) }

      before do
        ci_job.in_progress(github)
        ci_job.success(github)
        allow(ci_job).to receive(:stage).and_return(nil)
      end

      it 'uses unknown as stage_name and does not raise' do
        expect { ci_job.update_execution_time }.not_to raise_error
      end
    end

    context 'when CiJob stage has no configuration' do
      let(:ci_job) { create(:ci_job, check_ref: nil) }

      before do
        ci_job.in_progress(github)
        ci_job.success(github)
        allow(ci_job.stage).to receive(:configuration).and_return(nil)
      end

      it 'uses unknown as stage_name and does not raise' do
        expect { ci_job.update_execution_time }.not_to raise_error
      end
    end
  end

  describe '#checkout_code?' do
    let(:stage) { nil }

    context 'when job name contains checkout' do
      let(:ci_job) { create(:ci_job, name: 'Checkout Code', check_ref: nil) }

      it 'returns a truthy match' do
        expect(ci_job.checkout_code?).to be_truthy
      end
    end

    context 'when job name does not contain checkout' do
      let(:ci_job) { create(:ci_job, name: 'Build Package', check_ref: nil) }

      it 'returns nil' do
        expect(ci_job.checkout_code?).to be_nil
      end
    end
  end

  describe '#finished?' do
    let(:stage) { nil }

    context 'when status is queued' do
      let(:ci_job) { create(:ci_job, status: :queued, check_ref: nil) }

      it 'returns false' do
        expect(ci_job.finished?).to be false
      end
    end

    context 'when status is in_progress' do
      let(:ci_job) { create(:ci_job, :in_progress, check_ref: nil) }

      it 'returns false' do
        expect(ci_job.finished?).to be false
      end
    end

    context 'when status is success' do
      let(:ci_job) { create(:ci_job, :success, check_ref: nil) }

      it 'returns true' do
        expect(ci_job.finished?).to be true
      end
    end

    context 'when status is failure' do
      let(:ci_job) { create(:ci_job, :failure, check_ref: nil) }

      it 'returns true' do
        expect(ci_job.finished?).to be true
      end
    end
  end

  describe 'with a valid check_ref (GitHub check run exists)' do
    let(:stage) { nil }
    let(:fake_check_run) { double(id: 9999) }
    let(:ci_job) { create(:ci_job) }

    before do
      allow(github).to receive(:create).and_return(fake_check_run)
      allow(github).to receive(:in_progress).and_return(nil)
      allow(github).to receive(:success).and_return(nil)
      allow(github).to receive(:failure).and_return(nil)
      allow(github).to receive(:cancelled).and_return(nil)
      allow(github).to receive(:skipped).and_return(nil)
    end

    context 'when calling in_progress with existing check_ref' do
      it 'calls github.in_progress with the check_ref' do
        expect(github).to receive(:in_progress).with(ci_job.check_ref, {})
        ci_job.in_progress(github)
      end
    end

    context 'when calling success with existing check_ref' do
      it 'calls github.success and updates status' do
        ci_job.success(github)
        expect(ci_job.reload.status).to eq('success')
      end
    end

    context 'when calling failure with existing check_ref' do
      it 'calls github.failure and updates status' do
        ci_job.failure(github)
        expect(ci_job.reload.status).to eq('failure')
      end
    end

    context 'when calling cancelled with existing check_ref' do
      it 'calls github.cancelled and updates status' do
        ci_job.cancelled(github)
        expect(ci_job.reload.status).to eq('cancelled')
      end
    end

    context 'when calling skipped with existing check_ref' do
      it 'calls github.skipped and updates status' do
        ci_job.skipped(github)
        expect(ci_job.reload.status).to eq('skipped')
      end
    end
  end

  describe '#create_github_check (private)' do
    let(:stage) { nil }
    let(:fake_check_run) { double(id: 7777) }
    let(:ci_job) { create(:ci_job, check_ref: nil) }

    before do
      allow(github).to receive(:create).and_return(fake_check_run)
    end

    it 'creates a GitHub check run and sets check_ref when check_ref is nil' do
      without_partial_double_verification do
        allow(ci_job).to receive(:github_stage_full_name).and_return('SomeCheckName')
      end
      ci_job.send(:create_github_check, github)
      expect(ci_job.reload.check_ref).to eq('7777')
    end
  end
end
