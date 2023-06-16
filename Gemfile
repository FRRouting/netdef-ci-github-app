# frozen_string_literal: true

source 'https://rubygems.org'

ruby '~> 3.0.0'

# Token
gem 'jwt', '2.2.2'

gem 'octokit', '<= 4.17.0'

# Web Framework
gem 'sinatra', '2.0.8.1'

# ActiveRecord
gem 'otr-activerecord', '2.0.3'

# PostgreSQL adapter
gem 'pg', '1.2.3'

gem 'netrc'

gem 'puma'

# Code lint
gem 'rubocop', group: %i[development test]
gem 'rubocop-performance', group: %i[development test]

group :test do
  gem 'database_cleaner'
  gem 'factory_bot'
  gem 'faker'
  gem 'rack-test'
  gem 'rspec'
  gem 'webmock', require: 'webmock/rspec'
end
