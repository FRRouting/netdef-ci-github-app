#  SPDX-License-Identifier: BSD-2-Clause
#
#  checks_setup_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::ChecksSetup do
  let(:pull_request) { create(:pull_request) }
  let(:plan) { pull_request.plans.last }
  let!(:previous) { create(:check_suite, :with_stages, pull_request: pull_request, plan: plan) }
  let!(:check_suite) { create(:check_suite, pull_request: pull_request, plan: plan) }
  let(:fake_client) { Octokit::Client.new }
  let(:fake_github_check) { Github::Check.new(nil) }
  let(:fake_action) { double('Github::Build::Action', create_summary: true) }
  let(:resume) { false }
  let(:setup) do
    described_class.new(check_suite, plan, previous_check_suite: previous, github_user_id: 123, resume: resume)
  end

  before do
    allow(File).to receive(:read).and_return('')
    allow(OpenSSL::PKey::RSA).to receive(:new).and_return(OpenSSL::PKey::RSA.new(2048))
    allow(Octokit::Client).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:find_app_installations).and_return([{ 'id' => 1 }])
    allow(fake_client).to receive(:create_app_installation_access_token).and_return({ 'token' => 1 })

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:create).and_return(double(id: 1))
    allow(fake_github_check).to receive(:cancelled)
    allow(fake_github_check).to receive(:fetch_username).and_return({})

    allow(BambooCi::RunningPlan).to receive(:fetch).and_return([{ name: 'job', job_ref: 'JOB-1' }])
    allow(BambooCi::StopPlan).to receive(:comment)
    allow(Github::Build::Action).to receive(:new).and_return(fake_action)
    allow(SlackBot.instance).to receive(:execution_started_notification)
    allow(SlackBot.instance).to receive(:stage_finished_notification)
  end

  describe '#run' do
    it 'creates the summary and comments on the stopped execution' do
      expect(setup.run).to eq([200, 'Pull Request created'])
      expect(fake_action).to have_received(:create_summary).with(resume: false)
      expect(BambooCi::StopPlan).to have_received(:comment).with(previous, check_suite)
      expect(check_suite.reload.cancelled_previous_check_suite_id).to eq(previous.id)
    end

    it 'cancels the open stages of the stopped execution' do
      setup.run

      expect(previous.stages.reload.map(&:status)).to all(eq('cancelled'))
    end

    it 'records the user who triggered the execution' do
      allow(Github::UserInfo).to receive(:new)

      setup.run

      expect(Github::UserInfo).to have_received(:new).with(123, check_suite: check_suite)
    end

    it 'sends the execution started notification' do
      setup.run

      expect(SlackBot.instance).to have_received(:execution_started_notification).with(check_suite)
    end

    context 'when the Slack notification fails' do
      before do
        allow(SlackBot.instance).to receive(:execution_started_notification).and_raise(StandardError, 'slack down')
      end

      it 'still creates the summary' do
        expect(setup.run).to eq([200, 'Pull Request created'])
      end
    end

    context 'when Bamboo does not return the running plan' do
      before { allow(BambooCi::RunningPlan).to receive(:fetch).and_return([]) }

      it 'returns 422' do
        expect(setup.run).to eq([422, 'Failed to fetch RunningPlan'])
      end
    end

    context 'when GitHub fails' do
      before { allow(fake_action).to receive(:create_summary).and_raise(Octokit::NotFound) }

      it 'raises, so the caller can reschedule it' do
        expect { setup.run }.to raise_error(Octokit::NotFound)
      end
    end

    context 'when there is no previous execution' do
      let(:previous) { nil }

      it 'does not comment on Bamboo' do
        setup.run

        expect(BambooCi::StopPlan).not_to have_received(:comment)
      end
    end
  end

  describe '#run with resume' do
    let(:resume) { true }

    it 'resumes the summary without sending the notification again' do
      expect(setup.run).to eq([200, 'Pull Request created'])
      expect(fake_action).to have_received(:create_summary).with(resume: true)
      expect(SlackBot.instance).not_to have_received(:execution_started_notification)
    end

    context 'when the stop comment was already posted' do
      before { check_suite.update(cancelled_previous_check_suite_id: previous.id) }

      it 'does not post it again' do
        setup.run

        expect(BambooCi::StopPlan).not_to have_received(:comment)
      end
    end

    context 'when a newer execution has started' do
      before do
        check_suite
        create(:check_suite, pull_request: pull_request, plan: plan)
      end

      it 'does nothing' do
        expect(setup.run).to eq([200, 'Superseded by a newer execution'])
        expect(Github::Build::Action).not_to have_received(:new)
      end
    end
  end
end
