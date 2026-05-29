#  SPDX-License-Identifier: BSD-2-Clause
#
#  prometheus_metrics/metrics_definitions.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module PrometheusMetrics
  GAUGE_OPTS = { store_settings: { aggregation: :most_recent } }.freeze

  # --- Delayed Job metrics ---

  DJ_PENDING = REGISTRY.gauge(
    :delayed_jobs_pending,
    docstring: 'Delayed jobs waiting to run (run_at <= now, not locked, not failed)',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_RUNNING = REGISTRY.gauge(
    :delayed_jobs_running,
    docstring: 'Delayed jobs currently locked by a worker',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_SCHEDULED = REGISTRY.gauge(
    :delayed_jobs_scheduled,
    docstring: 'Delayed jobs scheduled to run in the future (run_at > now)',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_FAILED = REGISTRY.gauge(
    :delayed_jobs_failed,
    docstring: 'Delayed jobs that have permanently failed (failed_at IS NOT NULL)',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_MAX_ATTEMPTS_REACHED = REGISTRY.gauge(
    :delayed_jobs_max_attempts_reached,
    docstring: 'Delayed jobs that have exhausted all retry attempts',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_LOCKED_TOO_LONG = REGISTRY.gauge(
    :delayed_jobs_locked_too_long,
    docstring: 'Delayed jobs locked longer than max_run_time (5 min), indicating a stuck worker',
    labels: [:queue],
    **GAUGE_OPTS
  )
  DJ_TABLE = REGISTRY.gauge(
    :delayed_jobs_table,
    docstring: 'Unix timestamp of the next scheduled job per queue (0 when no job is scheduled)',
    labels: %i[job_id queue job_class job_args run_at],
    **GAUGE_OPTS
  )

  # --- CI domain metrics ---

  CI_JOBS = REGISTRY.gauge(
    :ci_jobs_total,
    docstring: 'CI jobs grouped by status',
    labels: [:status],
    **GAUGE_OPTS
  )
  CI_STAGES = REGISTRY.gauge(
    :ci_stages_total,
    docstring: 'CI stages grouped by status',
    labels: [:status],
    **GAUGE_OPTS
  )

  # --- Puma metrics ---

  PUMA_WORKERS_TOTAL = REGISTRY.gauge(:puma_workers_total,
                                      docstring: 'Total number of Puma worker processes configured',
                                      **GAUGE_OPTS)
  PUMA_BOOTED_WORKERS = REGISTRY.gauge(:puma_booted_workers,
                                       docstring: 'Number of Puma worker processes currently booted',
                                       **GAUGE_OPTS)
  PUMA_BACKLOG = REGISTRY.gauge(:puma_backlog,
                                docstring: 'Requests waiting for a Puma thread to become available, per worker',
                                labels: [:worker], **GAUGE_OPTS)
  PUMA_RUNNING_THREADS = REGISTRY.gauge(:puma_running_threads,
                                        docstring: 'Threads currently processing requests, per worker',
                                        labels: [:worker], **GAUGE_OPTS)
  PUMA_POOL_CAPACITY = REGISTRY.gauge(:puma_pool_capacity,
                                      docstring: 'Threads available for new requests, per worker',
                                      labels: [:worker], **GAUGE_OPTS)
  PUMA_MAX_THREADS = REGISTRY.gauge(:puma_max_threads,
                                    docstring: 'Maximum threads configured per worker',
                                    labels: [:worker], **GAUGE_OPTS)

  # --- ActiveRecord connection pool metrics ---

  AR_POOL_SIZE = REGISTRY.gauge(:activerecord_connection_pool_size,
                                docstring: 'Maximum number of connections allowed in the ActiveRecord connection pool',
                                **GAUGE_OPTS)
  AR_POOL_CONNECTIONS = REGISTRY.gauge(:activerecord_connection_pool_connections,
                                       docstring: 'Current number of connections in the ActiveRecord connection pool',
                                       **GAUGE_OPTS)
  AR_POOL_BUSY = REGISTRY.gauge(:activerecord_connection_pool_busy,
                                docstring: 'Connections currently checked out by a thread',
                                **GAUGE_OPTS)
  AR_POOL_IDLE = REGISTRY.gauge(:activerecord_connection_pool_idle,
                                docstring: 'Connections available for checkout',
                                **GAUGE_OPTS)
  AR_POOL_WAITING = REGISTRY.gauge(:activerecord_connection_pool_waiting,
                                   docstring: 'Threads waiting to obtain a connection from the pool',
                                   **GAUGE_OPTS)

  # --- ActiveRecord query metrics ---

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

  # --- HTTP requests ---

  HTTP_REQUESTS = REGISTRY.counter(
    :http_requests_total,
    docstring: 'Total HTTP requests handled by the app, by method, route pattern and status code',
    labels: %i[method path status]
  )
  HTTP_REQUEST_DURATION = REGISTRY.histogram(
    :http_request_duration_seconds,
    docstring: 'HTTP request duration in seconds, by route pattern',
    labels: [:path]
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
end
