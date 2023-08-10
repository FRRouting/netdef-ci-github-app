# frozen_string_literal: true

source 'https://rubygems.org'

ruby '~> 3.0.0'

# Token
gem 'jwt', '2.2.2'

gem 'octokit', '<= 4.17.0'

# Web Framework
gem 'sinatra', '2.0.8.1'

gem 'rack', '2.1.4'

# ActiveRecord
gem 'otr-activerecord', '2.0.3'

# PostgreSQL adapter
gem 'pg', '1.2.3'

gem 'netrc'

gem 'puma', '5.5.2'

# Code lint
gem 'rubocop', group: %i[development test]
gem 'rubocop-performance', group: %i[development test]

gem 'sidekiq'
gem 'sidekiq-cron'

group :test do
  gem 'database_cleaner'
  gem 'factory_bot'
  gem 'faker'
  gem 'rack-test'
  gem 'rspec'
  gem 'simplecov', require: false
  gem 'webmock', require: 'webmock/rspec'
end
