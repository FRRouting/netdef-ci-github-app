#  SPDX-License-Identifier: BSD-2-Clause
#
#  prometheus_metrics/refresh_helpers.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module PrometheusMetrics
  GAUGE_COUNT_MAP = {
    DJ_PENDING => :pending,
    DJ_RUNNING => :running,
    DJ_SCHEDULED => :scheduled,
    DJ_FAILED => :failed,
    DJ_MAX_ATTEMPTS_REACHED => :max_att,
    DJ_LOCKED_TOO_LONG => :stuck
  }.freeze

  def self.refresh_delayed_jobs
    reset_dj_gauges
    now = Time.now
    counts = dj_active_counts(now).merge(dj_problem_counts(now))
    all_queues = counts.values.flat_map(&:keys).uniq
    all_queues.each { |queue| set_dj_queue_gauges(queue, counts) }
  end

  def self.reset_dj_gauges
    GAUGE_COUNT_MAP.each_key do |gauge|
      gauge.values.each_key { |labels| gauge.set(0, labels: labels) }
    end
  end

  def self.dj_active_counts(now)
    {
      pending: Delayed::Job.where('run_at <= ? AND locked_at IS NULL AND failed_at IS NULL', now).group(:queue).count,
      running: Delayed::Job.where('locked_at IS NOT NULL AND failed_at IS NULL').group(:queue).count,
      scheduled: Delayed::Job.where('run_at > ? AND locked_at IS NULL AND failed_at IS NULL', now).group(:queue).count
    }
  end

  def self.dj_problem_counts(now)
    {
      failed: Delayed::Job.where('failed_at IS NOT NULL').group(:queue).count,
      max_att: Delayed::Job.where('attempts >= ? AND failed_at IS NULL', DJ_MAX_ATTEMPTS).group(:queue).count,
      stuck:
        Delayed::Job
          .where('locked_at IS NOT NULL AND locked_at < ? AND failed_at IS NULL', now - DJ_MAX_RUN_TIME)
          .group(:queue).count
    }
  end

  def self.set_dj_queue_gauges(queue, counts)
    q = { queue: queue.to_s }
    GAUGE_COUNT_MAP.each { |gauge, key| gauge.set(counts[key][queue].to_i, labels: q) }
  end

  def self.refresh_ci_domain
    CiJob.unscoped.group(:status).count.each do |status, count|
      CI_JOBS.set(count, labels: { status: status.to_s })
    end

    Stage.unscoped.group(:status).count.each do |status, count|
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
    stats[:worker_status].each { |w| update_puma_worker(w) }
  rescue Errno::ENOENT
    # tmp/puma_stats.json not written yet (first 30s after boot)
  end

  def self.update_puma_worker(worker)
    s = worker[:last_status]
    labels = { worker: worker[:index].to_s }
    PUMA_BACKLOG.set(s[:backlog].to_i, labels: labels)
    PUMA_RUNNING_THREADS.set(s[:running].to_i, labels: labels)
    PUMA_POOL_CAPACITY.set(s[:pool_capacity].to_i, labels: labels)
    PUMA_MAX_THREADS.set(s[:max_threads].to_i, labels: labels)
  end

  def self.refresh_scheduled_jobs_detail
    now = Time.now
    DJ_TABLE.values.each_key { |labels| DJ_TABLE.set(0, labels: labels) }

    Delayed::Job
      .where('run_at > ? AND locked_at IS NULL AND failed_at IS NULL', now)
      .select(:id, :queue, :handler, :run_at)
      .each { |job| record_scheduled_job(job) }
  end

  def self.record_scheduled_job(job)
    job_class, job_args = parse_dj_handler(job.handler)
    labels = {
      job_id: job.id.to_s,
      queue: job.queue.to_s,
      job_class: job_class,
      job_args: job_args,
      run_at: job.run_at
    }
    DJ_TABLE.set(job.run_at.to_i, labels: labels)
  end

  # Parses a Delayed::PerformableMethod YAML handler without loading arbitrary Ruby objects.
  # Returns [class::method string, truncated args string].
  def self.parse_dj_handler(handler)
    return ['Unknown', ''] unless handler

    obj_class   = extract_dj_class(handler)
    method_name = handler[/method_name: :(\S+)/, 1] || ''
    raw_args    = handler[/^args:\n(.*?)(?=\n\S|\z)/m, 1].to_s.strip
    args_str    = raw_args.gsub("\n", ', ').squeeze(' ')
    args_str    = "#{args_str[0, 77]}..." if args_str.length > 80

    ["#{obj_class}##{method_name}", args_str]
  rescue StandardError
    ['Unknown', '']
  end

  def self.extract_dj_class(handler)
    handler[%r{object: !ruby/class '([^']+)'}, 1] ||
      handler[%r{object: !ruby/object:(\S+)}, 1] ||
      handler[%r{!ruby/object:(\S+)}, 1] ||
      'Unknown'
  end

  private_class_method :refresh_delayed_jobs, :reset_dj_gauges, :dj_active_counts, :dj_problem_counts,
                       :set_dj_queue_gauges, :refresh_ci_domain, :refresh_connection_pool,
                       :refresh_puma, :update_puma_worker, :refresh_scheduled_jobs_detail,
                       :record_scheduled_job, :parse_dj_handler, :extract_dj_class
end
