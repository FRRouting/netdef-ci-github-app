#  SPDX-License-Identifier: BSD-2-Clause
#
#  sync_pending_jobs_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe SyncPendingJobs do
  it 'delegates to Summary::PendingJobs' do
    allow(Github::Build::Summary::PendingJobs).to receive(:sync_stage)

    described_class.sync(12, 'WatchDog')

    expect(Github::Build::Summary::PendingJobs).to have_received(:sync_stage).with(12, 'WatchDog')
  end
end
