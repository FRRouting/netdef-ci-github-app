# frozen_string_literal: true

FactoryBot.define do
  factory :ci_job do
    name { 'TEST CI' }
    status { 0 }
    job_ref { "FRR-UNITTEST-TESTCI-#{rand(1_000_000)}" }
    check_ref { rand(1_000_000) }

    check_suite
  end
end
