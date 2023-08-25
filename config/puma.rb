# frozen_string_literal: true
#  SPDX-License-Identifier: BSD-2-Clause
#
#  puma.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#

require_relative '../config/setup'
require 'puma'

workers 10

threads_count = (ENV['RAILS_MAX_THREADS'] || 5).to_i
threads 1, threads_count
port GitHubApp::Configuration.instance.config['port'] || 4667

preload_app!

pidfile 'puma.pid'
