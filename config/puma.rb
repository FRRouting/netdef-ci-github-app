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

workers 10

threads 1, (ENV['RAILS_MAX_THREADS'] || 5).to_i

port GitHubApp::Configuration.instance.config['port'] || 4667

activate_control_app

preload_app!

pidfile 'puma.pid'

before_fork do
  Thread.new do
    loop do
      Telemetry.instance.update_stats Puma.stats
      sleep 30
    end
  end
end
