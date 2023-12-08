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
  describe '#enqueue' do
    let(:stage) { create(:ci_job, stage: true) }
    let(:fake_client) { Octokit::Client.new }
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

    it 'must handle the error' do
      expect { stage.enqueue(github_fail) }.not_to raise_error
    end

    it 'must update status' do
      expect { stage.enqueue(github_success) }.not_to raise_error
      expect(stage.reload.status).to eq('queued')
    end
  end
end
