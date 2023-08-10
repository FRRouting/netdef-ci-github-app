# frozen_string_literal: true

require 'puma'

workers 10

threads_count = (ENV['RAILS_MAX_THREADS'] || 5).to_i
threads 1, threads_count

if GithubApp.production?
  port ENV.fetch('PORT', 4667)
else
  port ENV.fetch('PORT', 4668)
end

preload_app!

pidfile 'puma.pid'
