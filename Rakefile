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

task :environment do
  require_relative 'config/delayed_job'
end

namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task clear: :environment do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task work: :environment do
    Delayed::Worker.new(min_priority: ENV.fetch('MIN_PRIORITY', 1), max_priority: ENV.fetch('MAX_PRIORITY', 10)).start
  end
end

namespace :db do
  # Some db tasks require your app code to be loaded; they'll expect to find it here
  task :environment do
    require_relative 'database_loader'
  end
end
