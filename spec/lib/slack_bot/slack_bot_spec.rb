#  SPDX-License-Identifier: BSD-2-Clause
#
#  slack_bot_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe SlackBot do
  let(:slack_bot) { described_class.instance }
  let(:job) { create(:ci_job) }
  let(:subscription) { create(:pull_request_subscription) }
  let(:fake_config) { GitHubApp::Configuration.instance }
  let(:url) { 'https://test.free' }
  let(:pr) { job.check_suite.pull_request }
  let(:pr_url) { "https://github.com/#{pr.repository}/pull/#{pr.github_pr_id}" }
  let(:bamboo_link) { "https://ci1.netdef.org/browse/#{job.job_ref}" }

  before do
    stub_request(:post, "#{url}/github/comment").to_return(status: 200, body: '', headers: {})
    stub_request(:post, "#{url}/github/user").to_return(status: 200, body: '', headers: {})

    allow(GitHubApp::Configuration).to receive(:instance).and_return(fake_config)
    allow(fake_config).to receive(:config).and_return({ 'slack_bot_url' => url, 'github_apps' => [{}] })

    job
    subscription
  end

  context 'when testing notification message' do
    it { expect { slack_bot.notify_success(job) }.not_to raise_error }
    it { expect { slack_bot.notify_errors(job) }.not_to raise_error }
    it { expect { slack_bot.notify_cancelled(job) }.not_to raise_error }
    it { expect { slack_bot.execution_started_notification(job.check_suite) }.not_to raise_error }
    it { expect { slack_bot.execution_finished_notification(job.check_suite) }.not_to raise_error }
    it { expect { slack_bot.invalid_rerun_group(job) }.not_to raise_error }
    it { expect { slack_bot.invalid_rerun_dm(job, subscription) }.not_to raise_error }
    it { expect { slack_bot.stage_finished_notification(job.stage) }.not_to raise_error }
    it { expect { slack_bot.stage_in_progress_notification(job.stage) }.not_to raise_error }
  end

  context 'when not the current execution' do
    let(:pull_request) { job.check_suite.pull_request }
    let(:check_suite) { create(:check_suite, pull_request: pull_request) }

    before do
      create(:ci_job, check_suite: check_suite)
    end

    it { expect { slack_bot.notify_success(job) }.not_to raise_error }
    it { expect { slack_bot.notify_errors(job) }.not_to raise_error }
    it { expect { slack_bot.notify_cancelled(job) }.not_to raise_error }
    it { expect { slack_bot.execution_started_notification(job.check_suite) }.not_to raise_error }
    it { expect { slack_bot.execution_finished_notification(job.check_suite) }.not_to raise_error }
    it { expect { slack_bot.invalid_rerun_group(job) }.not_to raise_error }
    it { expect { slack_bot.invalid_rerun_dm(job, subscription) }.not_to raise_error }
    it { expect { slack_bot.stage_finished_notification(job.stage) }.not_to raise_error }
    it { expect { slack_bot.stage_in_progress_notification(job.stage) }.not_to raise_error }
  end
end
