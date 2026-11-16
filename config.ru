#  SPDX-License-Identifier: BSD-2-Clause
#
#  config.ru
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'rack'
require 'rackup'
require 'rack/handler/puma'
require 'rack/session/cookie'
require 'securerandom'
require 'prometheus/middleware/collector'
require 'prometheus/middleware/exporter'

require_relative 'app/github_app'
require_relative 'config/delayed_job'
require_relative 'lib/helpers/prometheus_metrics'

PrometheusMetrics.cleanup_stale_metric_files!
PrometheusMetrics.subscribe_query_notifications!

File.write('.session.key', SecureRandom.hex(32))

# Refresh delayed_job + CI domain gauges on every Prometheus scrape
use Prometheus::Middleware::Collector, metrics_prefix: 'http'

# Embedded job workers (every queue). Deployments that run the workers as their own services
# (deploy/ansible) set NETDEF_CI_EMBEDDED_WORKERS=false.
pids = []
if ENV.fetch('NETDEF_CI_EMBEDDED_WORKERS', 'true') != 'false'
  3.times { pids << spawn("RACK_ENV=#{ENV.fetch('RACK_ENV', 'development')} rake jobs:work") }
end

use Rack::Session::Cookie, secret: File.read('.session.key'), same_site: true, max_age: 86_400

Rackup::Handler::Puma.run Rack::URLMap.new('/' => GithubApp)

pids.each do |pid|
  Process.kill('TERM', pid.to_i)
rescue Errno::ESRCH
  puts "Process #{pid} already dead"
end

exit 0
