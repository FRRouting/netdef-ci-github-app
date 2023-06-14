# frozen_string_literal: true

FactoryBot.define do
  factory :check_suite do
    author { 'John Doe' }
    commit_sha_ref { 'abc1234' }
    base_sha_ref { 'qwerty1' }
    bamboo_ci_ref { "FRR-UNITTEST-#{rand(1_000_000)}" }
    merge_branch { 'master' }
    work_branch { 'unit_test' }

    pull_request

    trait :with_running_ci_jobs do
      after(:create) do |check_suite|
        create(:ci_job, check_suite: check_suite, status: :in_progress)
      end
    end
  end
end
