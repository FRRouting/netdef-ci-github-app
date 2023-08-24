# frozen_string_literal: true

require 'puma'
require_relative '../config/setup'

workers 10

threads_count = (ENV['RAILS_MAX_THREADS'] || 5).to_i
threads 1, threads_count

port ::Configuration.instance.config['port'] || 4667

preload_app!

pidfile 'puma.pid'
