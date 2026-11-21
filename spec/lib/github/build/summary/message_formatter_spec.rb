#  SPDX-License-Identifier: BSD-2-Clause
#
#  message_formatter_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::Summary::MessageFormatter do
  let(:stage) { create(:stage, :in_progress, :with_check_suite) }
  let(:formatter) { described_class.new }

  before do
    create(:ci_job, :success, stage: stage, check_suite: stage.check_suite, name: 'Ubuntu 22.04 amd64 build')
  end

  context 'when the stage has jobs without webhook' do
    before do
      create(:ci_job, :without_webhook, :in_progress, stage: stage, check_suite: stage.check_suite,
                                                      name: 'Ubuntu 26.04 amd64 build', job_ref: 'FRR-PULLREQ3-U2604-1')
    end

    it 'lists them at the end with their status' do
      output = formatter.summary_basic_output(stage)

      expect(output).to end_with(
        ":warning: Jobs without webhook: 1/2 (status polled from Bamboo)\n\n" \
        '- **Ubuntu 26.04 amd64 build** (in_progress) -> ' \
        "https://#{GitHubApp::Configuration.instance.ci_url}/browse/FRR-PULLREQ3-U2604-1\n"
      )
    end
  end

  context 'when every job has a webhook' do
    it 'has no section for jobs without webhook' do
      expect(formatter.summary_basic_output(stage)).not_to include('without webhook')
    end
  end
end
