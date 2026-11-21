#  SPDX-License-Identifier: BSD-2-Clause
#
#  failure_notice_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe Github::ReRun::FailureNotice do
  let(:pull_request) { create(:pull_request, :with_check_suite, github_pr_id: 42) }
  let(:payload) { { 'comment' => { 'id' => 99, 'body' => 'ci:rerun' } } }
  let(:fake_github_check) { instance_double(Github::Check) }

  before do
    allow(GithubLogger).to receive_message_chain(:instance, :create).and_return(Logger.new(nil))
    allow(Github::Check).to receive(:new).and_return(fake_github_check)
    allow(fake_github_check).to receive(:comment_reaction_thumb_down)
    allow(fake_github_check).to receive(:add_comment)
  end

  describe '.notify' do
    it 'reacts with a thumbs-down to the command comment' do
      described_class.notify(pull_request, payload, 'PLAN', 'Failed to create CI Plan')

      expect(fake_github_check).to have_received(:comment_reaction_thumb_down).with(pull_request.repository, 99)
    end

    it 'comments on the pull request with the plan and the reason' do
      described_class.notify(pull_request, payload, 'PLAN', 'Failed to create CI Plan')

      expect(fake_github_check).to have_received(:add_comment)
        .with(42, a_string_including('`PLAN`', 'Failed to create CI Plan'), pull_request.repository)
    end

    it 'only comments when the payload has no comment id' do
      described_class.notify(pull_request, {}, 'PLAN', 'internal error')

      expect(fake_github_check).not_to have_received(:comment_reaction_thumb_down)
      expect(fake_github_check).to have_received(:add_comment)
    end

    it 'does nothing without a pull request' do
      described_class.notify(nil, payload, 'PLAN', 'internal error')

      expect(Github::Check).not_to have_received(:new)
    end

    it 'does not raise when GitHub refuses the notice' do
      allow(fake_github_check).to receive(:add_comment).and_raise(Octokit::Forbidden)

      expect { described_class.notify(pull_request, payload, 'PLAN', 'internal error') }.not_to raise_error
    end
  end
end
