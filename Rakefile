#  SPDX-License-Identifier: BSD-2-Clause
#
#  Rakefile
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'bundler/setup'
require 'otr-activerecord'

load 'tasks/otr-activerecord.rake'

require_relative 'config/delayed_job'
require_relative 'config/setup'

namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task :clear do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task :work do
    Delayed::Worker.new(
      min_priority: ENV.fetch('MIN_PRIORITY', 0),
      max_priority: ENV.fetch('MAX_PRIORITY', 10),
      quiet: false
    ).start
  end
end

namespace :db do
  # Some db tasks require your app code to be loaded; they'll expect to find it here
  task :environment do
    require_relative 'database_loader'
  end
end
