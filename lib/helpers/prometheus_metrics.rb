#  SPDX-License-Identifier: BSD-2-Clause
#
#  prometheus_metrics.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'prometheus/client'

module PrometheusMetrics
  REGISTRY = Prometheus::Client.registry
  DJ_MAX_ATTEMPTS = 5
  DJ_MAX_RUN_TIME = 300 # 5 minutes, matches Delayed::Worker.max_run_time

  # --- Delayed Job metrics ---

  DJ_PENDING = REGISTRY.gauge(
    :delayed_jobs_pending,
    docstring: 'Delayed jobs waiting to run (run_at <= now, not locked, not failed)',
    labels: [:queue]
  )
  DJ_RUNNING = REGISTRY.gauge(
    :delayed_jobs_running,
    docstring: 'Delayed jobs currently locked by a worker',
    labels: [:queue]
  )
  DJ_SCHEDULED = REGISTRY.gauge(
    :delayed_jobs_scheduled,
    docstring: 'Delayed jobs scheduled to run in the future (run_at > now)',
    labels: [:queue]
  )
  DJ_FAILED = REGISTRY.gauge(
    :delayed_jobs_failed,
    docstring: 'Delayed jobs that have permanently failed (failed_at IS NOT NULL)',
    labels: [:queue]
  )
  DJ_MAX_ATTEMPTS_REACHED = REGISTRY.gauge(
    :delayed_jobs_max_attempts_reached,
    docstring: 'Delayed jobs that have exhausted all retry attempts',
    labels: [:queue]
  )
  DJ_LOCKED_TOO_LONG = REGISTRY.gauge(
    :delayed_jobs_locked_too_long,
    docstring: 'Delayed jobs locked longer than max_run_time (5 min), indicating a stuck worker',
    labels: [:queue]
  )
  DJ_TABLE = REGISTRY.gauge(
    :delayed_jobs_table,
    docstring: 'Unix timestamp of the next scheduled job per queue (0 when no job is scheduled)',
    labels: %i[job_id queue job_class job_args run_at]
  )

  # --- CI domain metrics ---

  CI_JOBS = REGISTRY.gauge(
    :ci_jobs_total,
    docstring: 'CI jobs grouped by status',
    labels: [:status]
  )
  CI_STAGES = REGISTRY.gauge(
    :ci_stages_total,
    docstring: 'CI stages grouped by status',
    labels: [:status]
  )

  # --- Puma metrics (cluster stats written by master process to tmp/puma_stats.json) ---

  PUMA_WORKERS_TOTAL = REGISTRY.gauge(
    :puma_workers_total,
    docstring: 'Total number of Puma worker processes configured'
  )
  PUMA_BOOTED_WORKERS = REGISTRY.gauge(
    :puma_booted_workers,
    docstring: 'Number of Puma worker processes currently booted'
  )
  PUMA_BACKLOG = REGISTRY.gauge(
    :puma_backlog,
    docstring: 'Requests waiting for a Puma thread to become available, per worker',
    labels: [:worker]
  )
  PUMA_RUNNING_THREADS = REGISTRY.gauge(
    :puma_running_threads,
    docstring: 'Threads currently processing requests, per worker',
    labels: [:worker]
  )
  PUMA_POOL_CAPACITY = REGISTRY.gauge(
    :puma_pool_capacity,
    docstring: 'Threads available for new requests, per worker',
    labels: [:worker]
  )
  PUMA_MAX_THREADS = REGISTRY.gauge(
    :puma_max_threads,
    docstring: 'Maximum threads configured per worker',
    labels: [:worker]
  )

  # --- ActiveRecord connection pool metrics ---

  AR_POOL_SIZE = REGISTRY.gauge(
    :activerecord_connection_pool_size,
    docstring: 'Maximum number of connections allowed in the ActiveRecord connection pool'
  )
  AR_POOL_CONNECTIONS = REGISTRY.gauge(
    :activerecord_connection_pool_connections,
    docstring: 'Current number of connections in the ActiveRecord connection pool'
  )
  AR_POOL_BUSY = REGISTRY.gauge(
    :activerecord_connection_pool_busy,
    docstring: 'Connections currently checked out by a thread'
  )
  AR_POOL_IDLE = REGISTRY.gauge(
    :activerecord_connection_pool_idle,
    docstring: 'Connections available for checkout'
  )
  AR_POOL_WAITING = REGISTRY.gauge(
    :activerecord_connection_pool_waiting,
    docstring: 'Threads waiting to obtain a connection from the pool'
  )

  # --- ActiveRecord query metrics (populated via ActiveSupport::Notifications) ---

  AR_QUERIES = REGISTRY.counter(
    :activerecord_queries_total,
    docstring: 'Total number of SQL queries executed, by operation type and table',
    labels: %i[operation table]
  )
  AR_QUERY_DURATION = REGISTRY.histogram(
    :activerecord_query_duration_seconds,
    docstring: 'Duration of SQL queries in seconds, by operation type and table',
    labels: %i[operation table]
  )

  # --- GitHub webhook events ---

  GITHUB_WEBHOOK_EVENTS = REGISTRY.counter(
    :github_webhook_events_total,
    docstring: 'GitHub webhook events received by the app, by event type and processing result',
    labels: %i[event result]
  )

  # --- Bamboo CI API integration ---

  BAMBOO_REQUESTS = REGISTRY.counter(
    :bamboo_api_requests_total,
    docstring: 'HTTP requests made to the Bamboo CI API, by operation and outcome',
    labels: %i[operation status]
  )
  BAMBOO_DURATION = REGISTRY.histogram(
    :bamboo_api_request_duration_seconds,
    docstring: 'Duration of Bamboo CI API requests in seconds, by operation',
    labels: [:operation]
  )

  # --- CI job lifecycle ---

  CI_JOB_DURATION = REGISTRY.histogram(
    :ci_job_execution_seconds,
    docstring: 'CI job execution duration in seconds, by stage name and final status',
    labels: %i[stage status]
  )
  CI_JOB_RETRIES = REGISTRY.counter(
    :ci_job_retry_total,
    docstring: 'CI job retries triggered, by reason (partial or full)',
    labels: [:reason]
  )
  CI_TIMEOUTS = REGISTRY.counter(
    :ci_job_timeout_total,
    docstring: 'Check suites marked as hanged by the timeout watchdog (no update for >2h)'
  )

  # --- Application exceptions ---

  APP_EXCEPTIONS = REGISTRY.counter(
    :app_exceptions_total,
    docstring: 'Unhandled exceptions caught by the Sinatra app, by exception class and handler',
    labels: %i[class handler]
  )

  # --- Slack notifications ---

  SLACK_NOTIFICATIONS = REGISTRY.counter(
    :slack_notifications_total,
    docstring: 'Slack notifications sent by the app, by notification type and delivery status',
    labels: %i[type status]
  )

  # Wraps a Bamboo CI API call, recording request count and duration.
  # Returns the block result, or nil on exception (mirroring GitHubApp::Request behaviour).
  def self.track_bamboo(operation)
    start = Time.now
    result = yield
    BAMBOO_REQUESTS.increment(labels: { operation: operation, status: bamboo_response_status(result) })
    BAMBOO_DURATION.observe(Time.now - start, labels: { operation: operation })
    result
  rescue StandardError
    BAMBOO_REQUESTS.increment(labels: { operation: operation, status: 'error' })
    BAMBOO_DURATION.observe(Time.now - start, labels: { operation: operation })
    nil
  end

  # Wraps a Slack HTTP call, recording delivery count and status.
  # Returns the block result, or nil on exception.
  def self.track_slack(type)
    result = yield
    SLACK_NOTIFICATIONS.increment(labels: { type: type, status: result.nil? ? 'error' : 'sent' })
    result
  rescue StandardError
    SLACK_NOTIFICATIONS.increment(labels: { type: type, status: 'error' })
    nil
  end

  # Call once at startup to begin recording per-query metrics.
  def self.subscribe_query_notifications!
    ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      event     = ActiveSupport::Notifications::Event.new(*args)
      operation = extract_sql_operation(event.payload[:sql])
      next if operation.nil?

      labels = { operation: operation, table: extract_table_name(event.payload[:name]) }
      AR_QUERIES.increment(labels: labels)
      AR_QUERY_DURATION.observe(event.duration / 1000.0, labels: labels)
    end
  end

  def self.bamboo_response_status(result)
    return 'error' if result.nil?
    return 'success' unless result.respond_to?(:code)

    result.code.to_i < 400 ? 'success' : 'error'
  end
  private_class_method :bamboo_response_status

  def self.refresh!
    refresh_delayed_jobs
    refresh_scheduled_jobs_detail
    refresh_ci_domain
    refresh_connection_pool
    refresh_puma
  rescue StandardError => e
    warn "PrometheusMetrics#refresh! error: #{e.message}"
  end

  def self.extract_sql_operation(sql)
    op = sql.to_s.strip.split(/\s/, 2).first&.upcase
    op if %w[SELECT INSERT UPDATE DELETE].include?(op)
  end

  # Extracts the table/model name from ActiveRecord's event name (e.g. "User Load" => "users").
  def self.extract_table_name(name)
    return 'unknown' if name.nil? || name.empty?

    model = name.to_s.split.first
    return 'other' if %w[SCHEMA EXPLAIN TRANSACTION].include?(model&.upcase)

    model&.downcase&.gsub('::', '_') || 'unknown'
  end

  private_class_method :extract_sql_operation, :extract_table_name
end

require_relative 'prometheus_metrics/refresh_helpers'
