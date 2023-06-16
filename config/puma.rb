# frozen_string_literal: true

require 'puma'

workers 5

threads_count = Integer(ENV['RAILS_MAX_THREADS'] || 5)
threads 1, threads_count

port ENV.fetch('PORT', 4667)

preload_app!
