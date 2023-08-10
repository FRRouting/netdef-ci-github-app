#!/usr/bin/env ruby
# frozen_string_literal: true

require 'irb'

ENV['RAILS_ENV'] = ARGV.shift || 'production'

puts "Starting console: #{ENV.fetch('RAILS_ENV', nil)}"

require_relative '../database_loader'

IRB.start
