#  SPDX-License-Identifier: BSD-2-Clause
#
#  delayed_job_ctrl.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'singleton'
require_relative '../../config/delayed_job'

class DelayedJobCtrl
  include Singleton

  # :nocov:
  def initialize
    @threads = []
    @stop_requested = false
  end

  def create_worker(min_priority, max_priority)
    @threads <<
      Thread.new do
        worker = Delayed::Worker.new(min_priority: min_priority, max_priority: max_priority, quiet: false)

        Thread.exit if @stop_requested

        worker.start
      rescue StandardError
        Thread.exit
      end
  end
  # :nocov:
end
