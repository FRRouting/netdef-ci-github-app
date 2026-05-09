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
    docstring: 'Total number of SQL queries executed, by operation type',
    labels: [:operation]
  )
  AR_QUERY_DURATION = REGISTRY.histogram(
    :activerecord_query_duration_seconds,
    docstring: 'Duration of SQL queries in seconds, by operation type',
    labels: [:operation]
  )

  # Call once at startup to begin recording per-query metrics.
  def self.subscribe_query_notifications!
    ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      event     = ActiveSupport::Notifications::Event.new(*args)
      operation = extract_sql_operation(event.payload[:sql])
      next if operation.nil?

      labels = { operation: operation }
      AR_QUERIES.increment(labels: labels)
      AR_QUERY_DURATION.observe(event.duration / 1000.0, labels: labels)
    end
  end

  def self.refresh!
    refresh_delayed_jobs
    refresh_ci_domain
    refresh_connection_pool
    refresh_puma
  rescue StandardError => e
    warn "PrometheusMetrics#refresh! error: #{e.message}"
  end

  def self.refresh_delayed_jobs
    now = Time.now
    stuck_threshold = now - DJ_MAX_RUN_TIME

    pending   = Delayed::Job.where('run_at <= ? AND locked_at IS NULL AND failed_at IS NULL', now).group(:queue).count
    running   = Delayed::Job.where('locked_at IS NOT NULL AND failed_at IS NULL').group(:queue).count
    scheduled = Delayed::Job.where('run_at > ? AND locked_at IS NULL AND failed_at IS NULL', now).group(:queue).count
    failed    = Delayed::Job.where('failed_at IS NOT NULL').group(:queue).count
    max_att   = Delayed::Job.where('attempts >= ? AND failed_at IS NULL', DJ_MAX_ATTEMPTS).group(:queue).count
    stuck     = Delayed::Job.where('locked_at IS NOT NULL AND locked_at < ? AND failed_at IS NULL', stuck_threshold).group(:queue).count

    all_queues = (pending.keys + running.keys + scheduled.keys + failed.keys + max_att.keys + stuck.keys).uniq

    all_queues.each do |queue|
      q = { queue: queue.to_s }
      DJ_PENDING.set(pending[queue].to_i, labels: q)
      DJ_RUNNING.set(running[queue].to_i, labels: q)
      DJ_SCHEDULED.set(scheduled[queue].to_i, labels: q)
      DJ_FAILED.set(failed[queue].to_i, labels: q)
      DJ_MAX_ATTEMPTS_REACHED.set(max_att[queue].to_i, labels: q)
      DJ_LOCKED_TOO_LONG.set(stuck[queue].to_i, labels: q)
    end
  end

  def self.refresh_ci_domain
    CiJob.group(:status).count.each do |status, count|
      CI_JOBS.set(count, labels: { status: status.to_s })
    end

    Stage.group(:status).count.each do |status, count|
      CI_STAGES.set(count, labels: { status: status.to_s })
    end
  end

  def self.refresh_connection_pool
    stat = ActiveRecord::Base.connection_pool.stat
    AR_POOL_SIZE.set(stat[:size])
    AR_POOL_CONNECTIONS.set(stat[:connections])
    AR_POOL_BUSY.set(stat[:busy])
    AR_POOL_IDLE.set(stat[:idle])
    AR_POOL_WAITING.set(stat[:waiting])
  end

  def self.refresh_puma
    stats = JSON.parse(File.read('tmp/puma_stats.json'), symbolize_names: true)
    return unless stats.key?(:worker_status)

    PUMA_WORKERS_TOTAL.set(stats[:workers].to_i)
    PUMA_BOOTED_WORKERS.set(stats[:booted_workers].to_i)

    stats[:worker_status].each do |w|
      s = w[:last_status]
      labels = { worker: w[:index].to_s }
      PUMA_BACKLOG.set(s[:backlog].to_i, labels: labels)
      PUMA_RUNNING_THREADS.set(s[:running].to_i, labels: labels)
      PUMA_POOL_CAPACITY.set(s[:pool_capacity].to_i, labels: labels)
      PUMA_MAX_THREADS.set(s[:max_threads].to_i, labels: labels)
    end
  rescue Errno::ENOENT
    # tmp/puma_stats.json not written yet (first 30s after boot)
  end

  def self.extract_sql_operation(sql)
    op = sql.to_s.strip.split(/\s/, 2).first&.upcase
    op if %w[SELECT INSERT UPDATE DELETE].include?(op)
  end

  private_class_method :refresh_delayed_jobs, :refresh_ci_domain, :refresh_connection_pool,
                       :refresh_puma, :extract_sql_operation
end
