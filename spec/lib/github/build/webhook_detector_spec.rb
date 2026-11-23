#  SPDX-License-Identifier: BSD-2-Clause
#
#  webhook_detector_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::Build::WebhookDetector do
  let(:check_suite) { create(:check_suite, bamboo_ci_ref: 'FRR-PULLREQ3-25201') }
  let(:detector) { described_class.new(check_suite) }
  let(:update) { "Bash\nci/github_checks/in_progress.sh" }
  let(:complete) { "Bash\nci/github_checks/complete.sh" }
  let(:specs) do
    {
      'FRR-PULLREQ3-BUILD' => { name: 'Ubuntu 22.04 amd64 build', commands: [update, 'make', complete] },
      'FRR-PULLREQ3-U2604' => { name: 'Ubuntu 26.04 amd64 build', commands: ['make'] },
      'FRR-PULLREQ3-ASAN' => { name: 'ASAN', commands: [complete] },
      'FRR-PULLREQ3-CHECKOUT' => { name: 'Checkout Code', commands: [complete] }
    }
  end

  before { allow(BambooCi::PlanSpecs).to receive(:jobs).with('FRR-PULLREQ3').and_return(specs) }

  def job(key, name = 'Renamed job')
    { name: name, job_ref: "FRR-PULLREQ3-#{key}-25201" }
  end

  it 'accepts a job that runs both GitHub Check scripts' do
    expect(detector.webhook?(job('BUILD'))).to be(true)
  end

  it 'flags a job without the GitHub Check scripts and counts it' do
    expect { expect(detector.webhook?(job('U2604', 'Ubuntu 26.04 amd64 build'))).to be(false) }
      .to change { PrometheusMetrics::CI_JOBS_WITHOUT_WEBHOOK.get(labels: { plan: 'FRR-PULLREQ3' }) }.by(1)
  end

  it 'flags a job that only completes' do
    expect(detector.webhook?(job('ASAN', 'ASAN'))).to be(false)
  end

  it 'accepts Checkout Code with only the complete script' do
    expect(detector.webhook?(job('CHECKOUT', 'Checkout Code'))).to be(true)
  end

  it 'finds the job by name when its key is not in the specs' do
    expect(detector.webhook?({ name: 'Ubuntu 26.04 amd64 build', job_ref: 'OTHER-1' })).to be(false)
  end

  it 'keeps the webhook behaviour for a job the specs do not describe' do
    expect(detector.webhook?(job('NEW', 'New job'))).to be(true)
  end

  it 'reads the specs once per execution' do
    detector.webhook?(job('BUILD'))
    detector.webhook?(job('U2604'))

    expect(BambooCi::PlanSpecs).to have_received(:jobs).once
  end

  context 'when Bamboo does not give the specs' do
    let(:specs) { nil }

    it 'keeps the webhook behaviour' do
      expect(detector.webhook?(job('U2604'))).to be(true)
    end
  end

  context 'when the execution has no Bamboo reference' do
    let(:check_suite) { create(:check_suite, bamboo_ci_ref: nil) }

    it 'keeps the webhook behaviour without asking Bamboo' do
      expect(detector.webhook?(job('U2604'))).to be(true)
      expect(BambooCi::PlanSpecs).not_to have_received(:jobs)
    end
  end
end
