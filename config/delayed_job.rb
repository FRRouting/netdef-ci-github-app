#  SPDX-License-Identifier: BSD-2-Clause
#
#  delayed_job.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative '../lib/helpers/github_logger'
require_relative '../database_loader'

require 'delayed_job'
require 'active_support'

module Rails
  class << self
    attr_accessor :logger
  end
end

DELAYED_JOB_TIMER = 30

Rails.logger = GithubLogger.instance.create('delayed_job.log', Logger::INFO)
ActiveRecord::Base.logger = GithubLogger.instance.create('delayed_job.log', Logger::INFO)

# this is used by DJ to guess where tmp/pids is located (default)
RAILS_ROOT = File.expand_path(__FILE__)

Delayed::Worker.backend = :active_record
Delayed::Worker.destroy_failed_jobs = true
Delayed::Worker.sleep_delay = 5
Delayed::Worker.max_attempts = 5
Delayed::Worker.max_run_time = 5.minutes

Delayed::Job.delete_all

config = YAML.load_file('config/database.yml')[ENV.fetch('RACK_ENV', 'development')]
ActiveRecord::Base.establish_connection(config)
