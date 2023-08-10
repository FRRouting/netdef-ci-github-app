# frozen_string_literal: true

FactoryBot.define do
  factory :plan do
    bamboo_ci_plan_name { Faker::App.name }
    github_repo_name { Faker::App.name }
  end
end
