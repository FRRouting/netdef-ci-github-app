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
  end
end
