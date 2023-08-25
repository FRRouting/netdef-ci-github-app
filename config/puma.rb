# frozen_string_literal: true
require_relative '../config/setup'
require 'puma'

workers 10

threads_count = (ENV['RAILS_MAX_THREADS'] || 5).to_i
threads 1, threads_count
port GitHubApp::Configuration.instance.config['port'] || 4667

preload_app!

pidfile 'puma.pid'
