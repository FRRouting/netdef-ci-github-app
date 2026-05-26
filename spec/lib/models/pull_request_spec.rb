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
  let(:plan)  { create(:plan) }
  let(:plan2) { create(:plan) }
  let(:pull_request) { create(:pull_request, plans: [plan]) }

  # ─── Validations ────────────────────────────────────────────────────────────

  describe 'validations' do
    it 'is valid with all required attributes' do
      expect(pull_request).to be_valid
    end

    it 'requires author' do
      pr = build(:pull_request, author: nil)
      expect(pr).not_to be_valid
      expect(pr.errors[:author]).to include("can't be blank")
    end

    it 'requires github_pr_id' do
      pr = build(:pull_request, github_pr_id: nil)
      expect(pr).not_to be_valid
      expect(pr.errors[:github_pr_id]).to include("can't be blank")
    end

    it 'requires branch_name' do
      pr = build(:pull_request, branch_name: nil)
      expect(pr).not_to be_valid
      expect(pr.errors[:branch_name]).to include("can't be blank")
    end

    it 'requires repository' do
      pr = build(:pull_request, repository: nil)
      expect(pr).not_to be_valid
      expect(pr.errors[:repository]).to include("can't be blank")
    end
  end

  # ─── Associations ────────────────────────────────────────────────────────────

  describe 'associations' do
    # PRs without plan associations so the FK on plans.pull_request_id doesn't block destroy
    let(:pr_no_plans) { create(:pull_request, plans: []) }

    it 'deletes check_suites when the pull request is destroyed' do
      create(:check_suite, pull_request: pr_no_plans)
      expect { pr_no_plans.destroy }.to change(CheckSuite, :count).by(-1)
    end

    it 'deletes pull_request_subscriptions when the pull request is destroyed' do
      create(:pull_request_subscription, pull_request: pr_no_plans)
      expect { pr_no_plans.destroy }.to change(PullRequestSubscription, :count).by(-1)
    end

    it 'can have many plans' do
      pr = create(:pull_request, plans: [plan, plan2])
      expect(pr.plans.count).to eq(2)
    end
  end

  # ─── #finished? ─────────────────────────────────────────────────────────────

  describe '#finished?' do
    context 'when the pull request has no check suites' do
      let(:pull_request) { create(:pull_request, plans: [plan]) }

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when the pull request has check suites but no plans' do
      let(:pull_request) { create(:pull_request, plans: []) }

      before { create(:check_suite, pull_request: pull_request) }

      it 'returns true (vacuous all? over empty plans)' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when all plans have a finished check suite (no running stages)' do
      before { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'when a plan has a check suite with a running stage' do
      before do
        cs = create(:check_suite, pull_request: pull_request, plan: plan)
        create(:stage, check_suite: cs, status: :in_progress)
      end

      it 'returns false' do
        expect(pull_request.finished?).to be false
      end
    end

    context 'when a plan has a check suite with a queued stage' do
      before do
        cs = create(:check_suite, pull_request: pull_request, plan: plan)
        create(:stage, check_suite: cs, status: :queued)
      end

      it 'returns false' do
        expect(pull_request.finished?).to be false
      end
    end

    context 'when a plan has no matching check suite (check suite exists but with no plan)' do
      let(:pull_request) { create(:pull_request, :with_check_suite) }

      it 'returns false' do
        expect(pull_request.finished?).to be false
      end
    end

    context 'when a plan has a check suite with only successful stages' do
      before do
        cs = create(:check_suite, pull_request: pull_request, plan: plan)
        create(:stage, check_suite: cs, status: :success)
      end

      it 'returns true' do
        expect(pull_request.finished?).to be true
      end
    end

    context 'with multiple plans' do
      let(:pull_request) { create(:pull_request, plans: [plan, plan2]) }

      context 'when all plans have finished check suites' do
        before do
          create(:check_suite, pull_request: pull_request, plan: plan)
          create(:check_suite, pull_request: pull_request, plan: plan2)
        end

        it 'returns true' do
          expect(pull_request.finished?).to be true
        end
      end

      context 'when one plan has a running check suite' do
        before do
          create(:check_suite, pull_request: pull_request, plan: plan)
          cs2 = create(:check_suite, pull_request: pull_request, plan: plan2)
          create(:stage, check_suite: cs2, status: :in_progress)
        end

        it 'returns false' do
          expect(pull_request.finished?).to be false
        end
      end

      context 'when one plan has a finished check suite and the other has none' do
        before { create(:check_suite, pull_request: pull_request, plan: plan) }

        it 'returns false' do
          expect(pull_request.finished?).to be false
        end
      end
    end
  end

  # ─── #current_execution? ────────────────────────────────────────────────────

  describe '#current_execution?' do
    context 'when check_suite is the only one for its plan' do
      let(:cs) { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns true' do
        expect(pull_request.current_execution?(cs)).to be true
      end
    end

    context 'when check_suite is the most recent for its plan' do
      let!(:cs1) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs2) { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns true for cs2 (the last one)' do
        expect(pull_request.current_execution?(cs2)).to be true
      end

      it 'returns false for cs1 (older)' do
        expect(pull_request.current_execution?(cs1)).to be false
      end
    end

    context 'with multiple plans isolating executions per plan' do
      let(:pull_request) { create(:pull_request, plans: [plan, plan2]) }
      let!(:cs_p1) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs_p2) { create(:check_suite, pull_request: pull_request, plan: plan2) }

      it 'considers cs_p1 the current execution for plan' do
        expect(pull_request.current_execution?(cs_p1)).to be true
      end

      it 'considers cs_p2 the current execution for plan2' do
        expect(pull_request.current_execution?(cs_p2)).to be true
      end

      it 'does not mix plan executions' do
        expect(pull_request.current_execution?(cs_p1)).to be true
        expect(pull_request.current_execution?(cs_p2)).to be true
      end
    end
  end

  # ─── #current_execution_by_plan ─────────────────────────────────────────────

  describe '#current_execution_by_plan' do
    context 'when no check suite exists for the given plan' do
      it 'returns nil' do
        expect(pull_request.current_execution_by_plan(plan)).to be_nil
      end
    end

    context 'when one check suite exists for the plan' do
      let!(:cs) { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns it' do
        expect(pull_request.current_execution_by_plan(plan)).to eq(cs)
      end
    end

    context 'when multiple check suites exist for the plan' do
      let!(:cs1) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs2) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs3) { create(:check_suite, pull_request: pull_request, plan: plan) }

      it 'returns the last one by id' do
        expect(pull_request.current_execution_by_plan(plan)).to eq(cs3)
      end

      it 'does not return older check suites' do
        result = pull_request.current_execution_by_plan(plan)
        expect(result).not_to eq(cs1)
        expect(result).not_to eq(cs2)
      end
    end

    context 'with multiple plans' do
      let(:pull_request) { create(:pull_request, plans: [plan, plan2]) }
      let!(:cs_plan1) { create(:check_suite, pull_request: pull_request, plan: plan) }
      let!(:cs_plan2) { create(:check_suite, pull_request: pull_request, plan: plan2) }

      it 'returns the check suite for plan only' do
        expect(pull_request.current_execution_by_plan(plan)).to eq(cs_plan1)
      end

      it 'returns the check suite for plan2 only' do
        expect(pull_request.current_execution_by_plan(plan2)).to eq(cs_plan2)
      end

      it 'does not cross plans' do
        expect(pull_request.current_execution_by_plan(plan)).not_to eq(cs_plan2)
        expect(pull_request.current_execution_by_plan(plan2)).not_to eq(cs_plan1)
      end
    end
  end

  # ─── .unique_repository_names ───────────────────────────────────────────────

  describe '.unique_repository_names' do
    context 'when no pull requests exist' do
      it 'returns an empty array' do
        expect(PullRequest.unique_repository_names).to be_empty
      end
    end

    context 'when multiple PRs share the same repository' do
      before do
        create(:pull_request, repository: 'org/repo', github_pr_id: 1)
        create(:pull_request, repository: 'org/repo', github_pr_id: 2)
        create(:pull_request, repository: 'org/repo', github_pr_id: 3)
      end

      it 'returns exactly one entry for that repository' do
        expect(PullRequest.unique_repository_names.count('org/repo')).to eq(1)
      end
    end

    context 'when PRs have entirely different repositories' do
      before do
        create(:pull_request, repository: 'org/repo-a', github_pr_id: 1)
        create(:pull_request, repository: 'org/repo-b', github_pr_id: 2)
      end

      it 'returns all distinct repository names' do
        expect(PullRequest.unique_repository_names).to contain_exactly('org/repo-a', 'org/repo-b')
      end
    end

    context 'when PRs mix repeated and unique repositories' do
      before do
        create(:pull_request, repository: 'org/repo-a', github_pr_id: 1)
        create(:pull_request, repository: 'org/repo-a', github_pr_id: 2)
        create(:pull_request, repository: 'org/repo-b', github_pr_id: 3)
      end

      it 'deduplicates correctly' do
        expect(PullRequest.unique_repository_names).to contain_exactly('org/repo-a', 'org/repo-b')
      end
    end
  end
end
