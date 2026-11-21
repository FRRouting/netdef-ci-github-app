#  SPDX-License-Identifier: BSD-2-Clause
#
#  pr_bamboo_sync_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../../workers/pr_bamboo_sync'

describe PrBambooSync do
  let(:sync) { described_class.new }
  let(:github) { instance_double(Github::Check) }
  let(:octokit) { double }
  let(:sha) { 'a' * 40 }
  let(:repo) { 'Unit/Test' }
  let(:pr_object) { { number: 24_358, head: { sha: sha }, updated_at: 3.hours.ago } }
  let(:pull_request) { create(:pull_request, github_pr_id: 24_358, repository: repo) }
  let!(:check_suite) do
    create(:check_suite, pull_request: pull_request, commit_sha_ref: sha, bamboo_ci_ref: 'PLAN-1')
  end
  let(:bamboo_status) { { 'finished' => false, 'currentStage' => 'Build' } }

  before do
    allow(GithubLogger.instance).to receive(:create).and_return(Logger.new(File::NULL))
    allow(sync).to receive(:puts)
    allow(Github::Check).to receive(:new).and_return(github)
    allow(github).to receive(:app).and_return(octokit)
    allow(octokit).to receive(:pull_requests).and_return([pr_object, pr_object.merge(updated_at: 1.hour.ago)])
    allow(github).to receive(:check_runs_for_ref).and_return({ check_runs: [{ id: 1 }] })
    allow(sync).to receive(:get_request).and_return(bamboo_status)
  end

  describe '#perform' do
    context 'when the Bamboo build is still running' do
      it 'reads the head SHA of each PR in the window and leaves the suite alone' do
        allow(Github::PlanExecution::Finished).to receive(:new)

        sync.perform

        expect(github).to have_received(:check_runs_for_ref).with(repo, sha, status: 'in_progress')
        expect(Github::PlanExecution::Finished).not_to have_received(:new)
      end
    end

    context 'when Bamboo already finished but GitHub still shows active runs' do
      let(:bamboo_status) { { 'finished' => true, 'currentStage' => 'Final' } }
      let(:finished) { instance_double(Github::PlanExecution::Finished, finished: true) }

      it 'synchronizes the stale check suite' do
        allow(Github::PlanExecution::Finished).to receive(:new).and_return(finished)

        sync.perform

        expect(Github::PlanExecution::Finished)
          .to have_received(:new).with({ 'bamboo_ref' => 'PLAN-1', 'hanged' => true })
      end

      it 'logs and continues when the synchronization raises' do
        allow(Github::PlanExecution::Finished).to receive(:new).and_raise(StandardError, 'boom')

        expect { sync.perform }.not_to raise_error
      end
    end

    context 'when Bamboo cannot be reached' do
      it 'reports the reference for manual review' do
        allow(sync).to receive(:get_request).and_raise(StandardError, 'timeout')

        sync.perform

        expect(sync).to have_received(:puts).with('  => PR #24358 (Unit/Test) PLAN-1')
      end
    end

    context 'when GitHub has no active check run for the PR head' do
      it 'does not query Bamboo' do
        allow(github).to receive(:check_runs_for_ref).and_return({ check_runs: [] })

        sync.perform

        expect(sync).not_to have_received(:get_request)
      end
    end

    context 'when GitHub fails while listing the check runs' do
      it 'does not query Bamboo' do
        allow(github).to receive(:check_runs_for_ref).and_raise(StandardError, 'rate limited')

        sync.perform

        expect(sync).not_to have_received(:get_request)
      end
    end

    context 'when GitHub fails while listing the pull requests' do
      it 'skips the repository' do
        allow(octokit).to receive(:pull_requests).and_raise(StandardError, 'rate limited')

        sync.perform

        expect(github).not_to have_received(:check_runs_for_ref)
      end
    end

    context 'when the GitHub client cannot be built' do
      it 'skips the repository' do
        allow(Github::Check).to receive(:new).and_raise(StandardError, 'bad key')

        sync.perform

        expect(octokit).not_to have_received(:pull_requests)
      end
    end
  end

  describe '#bamboo_finished?' do
    it 'treats a missing status as finished' do
      expect(sync.send(:bamboo_finished?, nil)).to be(true)
    end

    it 'treats a stopped plan as finished' do
      expect(sync.send(:bamboo_finished?, { 'message' => 'not running' })).to be(true)
    end

    it 'treats a complete progress probe as finished' do
      expect(sync.send(:bamboo_finished?, { 'finished' => false, 'progress' => { 'percentageCompleted' => 2.0 } }))
        .to be(true)
    end

    it 'treats a build in progress as running' do
      expect(sync.send(:bamboo_finished?, bamboo_status)).to be(false)
    end
  end
end
