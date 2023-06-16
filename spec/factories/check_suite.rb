# frozen_string_literal: true

FactoryBot.define do
  factory :check_suite do
    author { Faker::Name.name }
    commit_sha_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }
    base_sha_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }
    bamboo_ci_ref { Faker::Alphanumeric.alphanumeric(number: 18, min_alpha: 3, min_numeric: 3) }
    merge_branch { 'master' }
    work_branch { Faker::Team.creature }

    pull_request

    trait :with_running_ci_jobs do
      after(:create) do |check_suite|
        create(:ci_job, check_suite: check_suite, status: :in_progress)
      end
    end

    trait :with_running_success_ci_jobs do
      after(:create) do |check_suite|
        create_list(:ci_job, 5, check_suite: check_suite, status: 0)
        create_list(:ci_job, 5, check_suite: check_suite, status: 1)
        create_list(:ci_job, 5, check_suite: check_suite, status: 2)
      end
    end
  end
end
