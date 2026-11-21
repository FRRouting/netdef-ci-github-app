#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan_specs_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe BambooCi::PlanSpecs do
  let(:url) { 'https://127.0.0.1/rest/api/latest/plan/FRR-PULLREQ3/specs?format=YAML' }
  let(:yaml) do
    <<~YAML
      ---
      version: 2
      plan:
        project-key: FRR
        key: PULLREQ3
        name: FRR-Pull-Requests
      stages:
      - Building Stage:
          jobs:
          - Ubuntu 22.04 amd64 build
          - Ubuntu 26.04 amd64 build
      Ubuntu 22.04 amd64 build:
        key: U22AMD64BUILD
        tasks:
        - script:
            interpreter: SHELL
            scripts:
            - git clone ci
            description: Download CI scripts
        - command:
            executable: Bash
            argument: ci/github_checks/in_progress.sh
            description: Github Check - Update
        final-tasks:
        - command:
            executable: Bash
            argument: ci/github_checks/complete.sh
            description: Github Check - Complete
      Ubuntu 26.04 amd64 build:
        key: U2604AMD64
        tasks:
        - command:
            executable: Bash
            argument: ci/github_checks/in_progress.sh
            enabled: false
        - command:
            executable: Bash
            argument: ci/build-server/make_dist.sh
      ---
      version: 2
      plan-permissions:
        plan: FRR-PULLREQ3
    YAML
  end

  before { allow(Netrc).to receive(:read).and_return({ 'ci1.netdef.org' => %w[user password] }) }

  def stub_specs(body, status: 200)
    stub_request(:get, url).to_return(status: status, body: body)
  end

  context 'when Bamboo answers the specs inside JSON' do
    before { stub_specs({ spec: { code: yaml } }.to_json) }

    it 'returns the enabled task text of each job, by job key' do
      jobs = described_class.jobs('FRR-PULLREQ3')

      expect(jobs.keys).to contain_exactly('FRR-PULLREQ3-U22AMD64BUILD', 'FRR-PULLREQ3-U2604AMD64')
      expect(jobs['FRR-PULLREQ3-U22AMD64BUILD'][:name]).to eq('Ubuntu 22.04 amd64 build')
      expect(jobs['FRR-PULLREQ3-U22AMD64BUILD'][:commands].join).to include('in_progress.sh', 'complete.sh')
    end

    it 'leaves out disabled tasks' do
      commands = described_class.jobs('FRR-PULLREQ3')['FRR-PULLREQ3-U2604AMD64'][:commands]

      expect(commands).to eq(["Bash\nci/build-server/make_dist.sh"])
    end
  end

  context 'when Bamboo answers the specs in a top-level code field' do
    before { stub_specs({ code: yaml }.to_json) }

    it 'reads the jobs' do
      expect(described_class.jobs('FRR-PULLREQ3').size).to eq(2)
    end
  end

  context 'when Bamboo answers JSON that is not an object' do
    before { stub_specs('[]') }

    it 'returns nil' do
      expect(described_class.jobs('FRR-PULLREQ3')).to be_nil
    end
  end

  context 'when Bamboo answers the YAML itself' do
    before { stub_specs(yaml) }

    it 'reads the jobs' do
      expect(described_class.jobs('FRR-PULLREQ3').size).to eq(2)
    end
  end

  context 'when the user lacks VIEW_CONFIGURATION' do
    before do
      stub_specs({ message: "You don't have VIEW_CONFIGURATION permission", 'status-code': 403 }.to_json, status: 403)
    end

    it 'returns nil' do
      expect(described_class.jobs('FRR-PULLREQ3')).to be_nil
    end
  end

  context 'when Bamboo answers nothing' do
    before { stub_specs('') }

    it 'returns nil' do
      expect(described_class.jobs('FRR-PULLREQ3')).to be_nil
    end
  end

  context 'when the specs are not valid YAML' do
    before { stub_specs("plan: [unclosed\n") }

    it 'returns nil' do
      expect(described_class.jobs('FRR-PULLREQ3')).to be_nil
    end
  end

  context 'when a task is disabled at the task level' do
    let(:yaml) do
      <<~YAML
        Job:
          key: JOB
          tasks:
          - enabled: false
            command:
              argument: ci/github_checks/in_progress.sh
          - plain text task
      YAML
    end

    before { stub_specs(yaml) }

    it 'leaves it out and keeps tasks that are not hashes' do
      expect(described_class.jobs('FRR-PULLREQ3')['FRR-PULLREQ3-JOB'][:commands]).to eq(['plain text task'])
    end
  end
end
