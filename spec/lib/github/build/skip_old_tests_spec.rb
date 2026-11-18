#  SPDX-License-Identifier: BSD-2-Clause
#
#  skip_old_tests_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::SkipOldTests do
  let(:check_suite) { create(:check_suite) }
  let(:fake_github_check) { instance_double(Github::Check, skipped: true) }
  let(:configuration) { create(:stage_configuration, github_check_run_name: 'Build') }
  let(:app) { { name: 'NetDEF CI Hook' } }
  let(:check_runs) do
    [{ id: 1, name: '[CI] Build', app: app },
     { id: 2, name: '[CI] Build - FRR', app: app },
     { id: 3, name: '[CI] Removed stage', app: app },
     { id: 4, name: '[CI] Removed stage', app: { name: 'Other app' } }]
  end

  before do
    configuration
    create(:plan, name: 'FRR', github_repo_name: check_suite.pull_request.repository)

    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:check_runs_for_ref).and_return({ check_runs: check_runs })

    described_class.new(check_suite).skip_old_tests
  end

  it 'keeps the current stage check runs, with or without the plan suffix' do
    expect(fake_github_check).not_to have_received(:skipped).with(1, anything)
    expect(fake_github_check).not_to have_received(:skipped).with(2, anything)
  end

  it 'skips the NetDEF check runs of stages that are no longer configured' do
    expect(fake_github_check).to have_received(:skipped).with(3, anything).at_least(:once)
    expect(fake_github_check).not_to have_received(:skipped).with(4, anything)
  end
end
