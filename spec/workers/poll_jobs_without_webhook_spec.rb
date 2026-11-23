#  SPDX-License-Identifier: BSD-2-Clause
#
#  poll_jobs_without_webhook_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe PollJobsWithoutWebhook do
  it 'delegates to Github::Build::JobsWithoutWebhook' do
    allow(Github::Build::JobsWithoutWebhook).to receive(:poll)

    described_class.poll(42)

    expect(Github::Build::JobsWithoutWebhook).to have_received(:poll).with(42)
  end
end
