# frozen_string_literal: true

FactoryBot.define do
  factory :pull_request do
    author { 'John Doe' }
    github_pr_id { 1 }
    branch_name { 'unit_test' }
    repository { 'Unit/Test' }
    plan { 'FRR-UNITTEST' }
  end
end
