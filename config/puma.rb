#  SPDX-License-Identifier: BSD-2-Clause
#
#  puma.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/setup'
require 'puma'
require 'puma/metrics/app'

workers 10

plugin :metrics

threads 1, (ENV['RAILS_MAX_THREADS'] || 5).to_i

metrics_port = ENV['RACK_ENV'] == 'production' ? 9393 : 9394

metrics_url "tcp://0.0.0.0:#{metrics_port}"

port GitHubApp::Configuration.instance.config['port'] || 4667

preload_app!

pidfile 'puma.pid'
