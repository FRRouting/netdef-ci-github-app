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
require 'prometheus/client/data_stores/direct_file_store'
require 'fileutils'

module PrometheusMetrics
  METRICS_DIR = ENV.fetch('PROMETHEUS_METRICS_DIR', '/tmp/prometheus_metrics')
  FileUtils.mkdir_p(METRICS_DIR)
  Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir: METRICS_DIR)

  REGISTRY = Prometheus::Client.registry
  DJ_MAX_ATTEMPTS = 5
  DJ_MAX_RUN_TIME = 300 # 5 minutes, matches Delayed::Worker.max_run_time
end

require_relative 'prometheus_metrics/metrics_definitions'
require_relative 'prometheus_metrics/refresh_helpers'

module PrometheusMetrics
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

  def self.track_slack(type)
    result = yield
    SLACK_NOTIFICATIONS.increment(labels: { type: type, status: result.nil? ? 'error' : 'sent' })
    result
  rescue StandardError
    SLACK_NOTIFICATIONS.increment(labels: { type: type, status: 'error' })
    nil
  end

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

  def self.cleanup_stale_metric_files!
    Dir.glob(File.join(METRICS_DIR, 'metric_*___*.bin')).each do |path|
      pid = File.basename(path)[/___(\d+)\.bin$/, 1]&.to_i
      File.delete(path) if pid && pid != Process.pid && !process_alive?(pid)
    end
  rescue StandardError => e
    warn "PrometheusMetrics#cleanup_stale_metric_files! error: #{e.message}"
  end

  def self.refresh!
    refresh_delayed_jobs
    refresh_scheduled_jobs_detail
    refresh_ci_domain
    refresh_connection_pool
    refresh_puma
  rescue StandardError => e
    warn "PrometheusMetrics#refresh! error: #{e.message}"
  end

  def self.bamboo_response_status(result)
    return 'error' if result.nil?
    return 'success' unless result.respond_to?(:code)

    result.code.to_i < 400 ? 'success' : 'error'
  end

  def self.process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def self.extract_sql_operation(sql)
    op = sql.to_s.strip.split(/\s/, 2).first&.upcase
    op if %w[SELECT INSERT UPDATE DELETE].include?(op)
  end

  def self.extract_table_name(name)
    return 'unknown' if name.nil? || name.empty?

    model = name.to_s.split.first
    return 'other' if %w[SCHEMA EXPLAIN TRANSACTION].include?(model&.upcase)

    model&.downcase&.gsub('::', '_') || 'unknown'
  end

  private_class_method :bamboo_response_status, :process_alive?, :extract_sql_operation, :extract_table_name
end
