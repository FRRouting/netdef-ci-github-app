#  SPDX-License-Identifier: BSD-2-Clause
#
#  Gemfile
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.3.1'

# Token
gem 'jwt'

gem 'octokit', '~> 9.1'

# Web Framework
gem 'sinatra'

gem 'rack'

# ActiveRecord
gem 'otr-activerecord', '~> 2.3'

# PostgreSQL adapter
gem 'pg', '~> 1.5', '>= 1.5.3'

gem 'netrc'

gem 'puma'

gem 'rake'

# Delayed Job
gem 'delayed_job_active_record'

# Code lint
gem 'rubocop', '1.56.1', group: %i[development test]
gem 'rubocop-performance', group: %i[development test]
group :test do
  gem 'database_cleaner'
  gem 'factory_bot'
  gem 'faker'
  gem 'rack-test'
  gem 'rspec'
  gem 'simplecov', require: false
  gem 'webmock', require: 'webmock/rspec'
end

gem 'multipart-post', '~> 2.4'

gem 'faraday-retry', '~> 2.2'

gem 'faraday-multipart', '~> 1.0'
