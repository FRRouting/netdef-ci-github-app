#  SPDX-License-Identifier: BSD-2-Clause
#
#  watch_dog.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../config/sidekiq'
require_relative '../database_loader'

class WatchDog
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  def perform
    CheckSuite.joins(:ci_jobs).where(ci_jobs: { status: %w[queued in_progress] }).each do |check_suite|
      puts check_suite.inspect
    end
  end
end
