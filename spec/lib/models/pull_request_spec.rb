#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe PullRequest do
  describe 'validations' do
    subject { PullRequest.new(author: 'author', github_pr_id: 1, branch_name: 'main', repository: 'org/repo') }

    it 'is valid with all required attributes present' do
      expect(subject).to be_valid
    end

    it 'is invalid without author' do
      subject.author = nil
      expect(subject).not_to be_valid
    end

    it 'is invalid without github_pr_id' do
      subject.github_pr_id = nil
      expect(subject).not_to be_valid
    end

    it 'is invalid without branch_name' do
      subject.branch_name = nil
      expect(subject).not_to be_valid
    end

    it 'is invalid without repository' do
      subject.repository = nil
      expect(subject).not_to be_valid
    end
  end

  describe 'associations' do
    let(:pull_request) { create(:pull_request) }

    it 'has many check_suites' do
      cs = create(:check_suite, pull_request: pull_request)
      expect(pull_request.check_suites).to include(cs)
    end

    it 'deletes check_suites when the pull request is destroyed' do
      create(:check_suite, pull_request: pull_request)
      pull_request.plans.delete_all
      expect { pull_request.destroy }.to change(CheckSuite, :count).by(-1)
    end

    it 'has many pull_request_subscriptions' do
      sub = create(:pull_request_subscription, pull_request: pull_request)
      expect(pull_request.pull_request_subscriptions).to include(sub)
    end

    it 'deletes pull_request_subscriptions when the pull request is destroyed' do
      create(:pull_request_subscription, pull_request: pull_request)
      pull_request.plans.delete_all
      expect { pull_request.destroy }.to change(PullRequestSubscription, :count).by(-1)
    end

    it 'has many plans' do
      expect(pull_request.plans).not_to be_empty
    end
  end

  describe '#finished?' do
    context 'when check_suites is empty' do
      let(:pull_request) { create(:pull_request) }

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when plans exist and all current executions are finished' do
      let(:pull_request) { create(:pull_request) }
      let(:plan) { pull_request.plans.first }

      before do
        create(:check_suite, pull_request: pull_request, plan: plan)
      end

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when plans exist but no execution is found for a plan' do
      let(:pull_request) { create(:pull_request, :with_check_suite) }

      it 'returns false' do
        expect(pull_request.finished?).to be false
      end
    end

    context 'when plans exist and an execution is still running' do
      let(:pull_request) { create(:pull_request) }
      let(:plan) { pull_request.plans.first }

      before do
        cs = create(:check_suite, pull_request: pull_request, plan: plan)
        create(:stage, check_suite: cs, status: :in_progress)
      end

      it 'returns false' do
        expect(pull_request.finished?).to be false
      end
    end

    context 'when no plans exist and the last check_suite is finished' do
      let(:pull_request) { create(:pull_request) }

      before do
        pull_request.plans.delete_all
        create(:check_suite, pull_request: pull_request)
      end

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when no plans exist and the last check_suite is not finished' do
      let(:pull_request) { create(:pull_request) }

      before do
        pull_request.plans.delete_all
        cs = create(:check_suite, pull_request: pull_request)
        create(:stage, check_suite: cs, status: :in_progress)
      end

      it 'returns false' do
        expect(pull_request.finished?).to be_falsey
      end
    end
  end

  describe '#current_execution?' do
    let(:pull_request) { create(:pull_request) }
    let(:cs1) { create(:check_suite, pull_request: pull_request) }
    let(:cs2) { create(:check_suite, pull_request: pull_request) }

    before do
      cs1
      cs2
    end

    it 'returns true when the check_suite is the latest execution for its plan' do
      expect(pull_request.current_execution?(cs2)).to be true
    end

    it 'returns false when the check_suite is not the latest execution for its plan' do
      expect(pull_request.current_execution?(cs1)).to be false
    end
  end

  describe '#current_execution_by_plan' do
    let(:pull_request) { create(:pull_request) }
    let(:plan) { pull_request.plans.first }

    context 'when check_suites exist for the given plan' do
      let!(:cs1) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs2) { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns the last check_suite ordered by id' do
        expect(pull_request.current_execution_by_plan(plan)).to eq(cs2)
      end
    end

    context 'when no check_suites exist for the given plan' do
      it 'returns nil' do
        expect(pull_request.current_execution_by_plan(plan)).to be_nil
      end
    end
  end

  describe '.unique_repository_names' do
    before do
      create(:pull_request, repository: 'org/repo-a')
      create(:pull_request, repository: 'org/repo-a')
      create(:pull_request, repository: 'org/repo-b')
    end

    it 'returns distinct repository names without duplicates' do
      expect(PullRequest.unique_repository_names).to contain_exactly('org/repo-a', 'org/repo-b')
    end
  end
end
