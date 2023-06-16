# frozen_string_literal: true

FactoryBot.define do
  factory :pull_request do
    author { Faker::Name.name }
    github_pr_id { 1 }
    branch_name { Faker::App.name }
    repository { 'Unit/Test' }
    plan { Faker::Alphanumeric.alpha(number: 10) }
  end
end
