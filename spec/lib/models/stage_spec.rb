#  SPDX-License-Identifier: BSD-2-Clause
#
#  stage_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Stage do
  let(:fake_client) { Octokit::Client.new }
  let(:github) { Github::Check.new(nil) }
  let(:fake_response) { create(:stage) }

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(github).to receive(:create).and_return(fake_response)
    allow(github).to receive(:queued)
    allow(github).to receive(:cancelled)
    allow(github).to receive(:failure)
    allow(github).to receive(:success)
    allow(github).to receive(:in_progress)

    allow(SlackBot.instance).to receive(:stage_finished_notification)
    allow(SlackBot.instance).to receive(:stage_in_progress_notification)
  end

  describe '#create_github_check' do
    let(:stage) { create(:stage, check_ref: nil) }

    it 'must update status' do
      stage.cancelled(github)
      expect(stage.reload.status).to eq('cancelled')
    end
  end

  describe '#previous_stage' do
    context 'when has a valid config' do
      let(:stage) { create(:stage, :with_check_suite, check_ref: nil) }

      it 'must update status' do
        expect(stage.previous_stage).to be_nil
      end
    end

    context 'when has an invalid config' do
      let(:stage) { create(:stage, :with_check_suite, configuration: nil, check_ref: nil) }

      it 'must update status' do
        expect(stage.previous_stage).to be_nil
      end
    end
  end

  describe '#enqueue' do
    let(:stage) { create(:stage, :with_check_suite, check_ref: nil) }

    it 'must update status' do
      stage.enqueue(github)
      expect(stage.reload.status).to eq('queued')
    end
  end

  describe '#in_progress' do
    context 'when stage has not job' do
      let(:stage) { create(:stage, :with_check_suite) }

      it 'must update status' do
        stage.in_progress(github)
        expect(stage.reload.status).to eq('in_progress')
      end
    end

    context 'when stage has job' do
      let(:stage) { create(:stage, :with_check_suite, :with_job, check_ref: nil) }

      it 'must update status' do
        stage.in_progress(github)
        expect(stage.reload.status).to eq('in_progress')
      end
    end
  end

  describe '#failure' do
    let(:stage) { create(:stage, :with_check_suite, check_ref: nil) }

    it 'must update status' do
      stage.failure(github)
      expect(stage.reload.status).to eq('failure')
    end

    it 'must only update 1 time' do
      stage.failure(github)
      stage.failure(github)
      expect(stage.reload.status).to eq('failure')
    end
  end

  describe '#success' do
    let(:stage) { create(:stage, :with_check_suite, check_ref: nil) }

    it 'must update status' do
      stage.success(github)
      expect(stage.reload.status).to eq('success')
    end

    it 'must only update 1 time' do
      stage.success(github)
      stage.success(github)
      expect(stage.reload.status).to eq('success')
    end
  end
end
