#!/usr/bin/env ruby
#  SPDX-License-Identifier: BSD-2-Clause
#
#  console.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
# frozen_string_literal: true

require 'irb'

ENV['RAILS_ENV'] = ARGV.shift || 'production'

puts "Starting console: #{ENV.fetch('RAILS_ENV', nil)}"

require_relative '../database_loader'
require_relative '../lib/helpers/configuration'
require_relative '../lib/github/check'
require_relative '../lib/github/build/action'
require_relative '../lib/github/build/summary'

IRB.start
