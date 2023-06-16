# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
ENV['RAILS_ENV'] = 'test'

require_relative '../app/github_app'
require 'database_cleaner'
require 'factory_bot'
require 'faker'
require 'rspec'
require 'rack/test'
require 'webmock/rspec'

Dir["#{__dir__}/support/*.rb"].each { |file| require file }
Dir["#{__dir__}/factories/*.rb"].each { |file| load file }

def app
  GithubApp
end

DatabaseCleaner.strategy = :truncation

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.include FactoryBot::Syntax::Methods
  config.include WebMock::API

  config.before(:all) do
    DatabaseCleaner.clean
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.warnings = true
  config.profile_examples = 10
  config.order = :random
  Kernel.srand config.seed
end
