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

require_relative '../config/setup'
require_relative '../config/delayed_job'

IRB.start
