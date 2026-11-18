#  SPDX-License-Identifier: BSD-2-Clause
#
#  request_metrics.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'prometheus_metrics'

# Rack middleware that records the HTTP, webhook and exception metrics of GithubApp.
# Every label comes from a bounded set: the Sinatra route pattern (or 'unmatched'), known HTTP methods
# and known GitHub event names (or 'other'), so scanners and forged headers cannot create new series.
# A failure while recording is logged and never changes the response.
class RequestMetrics
  UNMATCHED = 'unmatched'
  OTHER = 'other'
  WEBHOOK_ROUTE = 'POST /*'
  HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze
  GITHUB_EVENTS = %w[ping pull_request check_run check_suite installation issue_comment].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    begin
      status, headers, body = @app.call(env)
    rescue StandardError => e
      env['sinatra.error'] ||= e
      safe_record(env, 500, start)
      raise
    end

    safe_record(env, status, start)

    [status, headers, body]
  end

  private

  def safe_record(env, status, start)
    record(env, status, start)
  rescue StandardError => e
    warn "RequestMetrics: could not record metrics: #{e.class}: #{e.message}"
  end

  def record(env, status, start)
    route = route_label(env)

    PrometheusMetrics::HTTP_REQUESTS.increment(
      labels: { method: method_label(env), path: route, status: status.to_s }
    )
    PrometheusMetrics::HTTP_REQUEST_DURATION.observe(elapsed(start), labels: { path: route })

    record_webhook(env, status)
    record_exception(env, status, route)
  end

  # Only the webhook route counts as a GitHub event, whatever header other requests carry.
  def record_webhook(env, status)
    event = env['HTTP_X_GITHUB_EVENT']
    return if event.nil? or env['sinatra.route'] != WEBHOOK_ROUTE

    event = event.to_s.downcase
    event = OTHER unless GITHUB_EVENTS.include?(event)

    PrometheusMetrics::GITHUB_WEBHOOK_EVENTS.increment(
      labels: { event: event, result: status.to_i < 400 ? 'processed' : 'error' }
    )
  end

  def record_exception(env, status, route)
    error = env['sinatra.error']
    return if error.nil? or status.to_i < 500

    PrometheusMetrics::APP_EXCEPTIONS.increment(labels: { class: error.class.name, handler: route })
  end

  def method_label(env)
    method = env['REQUEST_METHOD'].to_s.upcase
    HTTP_METHODS.include?(method) ? method : OTHER
  end

  def route_label(env)
    env['sinatra.route']&.split(' ', 2)&.last || UNMATCHED
  end

  def elapsed(start)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
