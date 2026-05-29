#  SPDX-License-Identifier: BSD-2-Clause
#
#  refresh_helpers_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe PrometheusMetrics do
  describe '.parse_dj_handler (private)' do
    subject(:result) { PrometheusMetrics.send(:parse_dj_handler, handler) }

    context 'when handler is nil' do
      let(:handler) { nil }

      it { is_expected.to eq(['Unknown', '']) }
    end

    context 'with a PerformableMethod handler using ruby/object' do
      let(:handler) do
        <<~YAML
          --- !ruby/object:Delayed::PerformableMethod
          object: !ruby/object:MyService
            id: 1
          method_name: :perform
          args:
          - arg_one
          - arg_two
        YAML
      end

      it 'returns the class and method name' do
        class_method, = result
        expect(class_method).to eq('MyService#perform')
      end

      it 'returns a non-empty args string' do
        _, args = result
        expect(args).not_to be_empty
      end
    end

    context 'with a PerformableMethod handler using ruby/class' do
      let(:handler) do
        <<~YAML
          --- !ruby/object:Delayed::PerformableMethod
          object: !ruby/class 'SomeWorker'
          method_name: :run
          args: []
        YAML
      end

      it 'returns the ruby/class name' do
        class_method, = result
        expect(class_method).to eq('SomeWorker#run')
      end
    end

    context 'when args exceed 80 characters' do
      let(:long_arg) { 'a' * 100 }
      let(:handler) do
        "--- !ruby/object:Delayed::PerformableMethod\n" \
          "object: !ruby/object:MyWorker\n" \
          "method_name: :process\n" \
          "args:\n" \
          "- #{long_arg}\n"
      end

      it 'truncates the args string with an ellipsis' do
        _, args = result
        expect(args).to end_with('...')
        expect(args.length).to be <= 83
      end
    end

    context 'when handler has no method_name' do
      let(:handler) do
        "--- !ruby/object:Delayed::PerformableMethod\nobject: !ruby/object:MyWorker\n"
      end

      it 'returns an empty string for the method name' do
        class_method, = result
        expect(class_method).to eq('MyWorker#')
      end
    end

    context 'when the handler is an unexpected format' do
      let(:handler) { "invalid: yaml: [[[" }

      it 'returns Unknown and empty args without raising' do
        expect { result }.not_to raise_error
      end
    end
  end

  describe '.extract_dj_class (private)' do
    subject(:klass) { PrometheusMetrics.send(:extract_dj_class, handler) }

    context 'with a ruby/class reference' do
      let(:handler) { "object: !ruby/class 'MyClass'" }

      it { is_expected.to eq('MyClass') }
    end

    context 'with a ruby/object reference on the object key' do
      let(:handler) { "object: !ruby/object:SomeService\n  id: 1" }

      it { is_expected.to eq('SomeService') }
    end

    context 'with a ruby/object in the root' do
      let(:handler) { "--- !ruby/object:AnotherWorker\n  id: 42" }

      it { is_expected.to eq('AnotherWorker') }
    end

    context 'with no recognizable class pattern' do
      let(:handler) { 'plain: yaml\nno class here' }

      it { is_expected.to eq('Unknown') }
    end
  end

  describe '.sanitized_gauge_labels (private)' do
    subject(:labels) { PrometheusMetrics.send(:sanitized_gauge_labels, gauge) }

    context 'when the gauge has no recorded values' do
      let(:gauge) { instance_double(Prometheus::Client::Gauge, values: {}) }

      it { is_expected.to eq([]) }
    end

    context 'when the gauge has values without a :pid key' do
      let(:gauge) do
        instance_double(Prometheus::Client::Gauge,
                        values: { { queue: 'default' } => 1, { queue: 'ci' } => 0 })
      end

      it 'returns the label hashes as-is' do
        expect(labels).to contain_exactly({ queue: 'default' }, { queue: 'ci' })
      end
    end

    context 'when the gauge has values with a :pid key' do
      let(:gauge) do
        instance_double(Prometheus::Client::Gauge,
                        values: {
                          { queue: 'default', pid: 1234 } => 1,
                          { queue: 'default', pid: 5678 } => 2
                        })
      end

      it 'strips :pid and deduplicates' do
        expect(labels).to eq([{ queue: 'default' }])
      end
    end
  end

  describe '.refresh_status_gauge (private)' do
    let(:gauge) { instance_double(Prometheus::Client::Gauge, values: {}) }

    before do
      allow(gauge).to receive(:set)
    end

    it 'resets previously known labels to 0' do
      allow(PrometheusMetrics).to receive(:sanitized_gauge_labels).with(gauge)
        .and_return([{ status: 'queued' }, { status: 'failed' }])

      expect(gauge).to receive(:set).with(0, labels: { status: 'queued' })
      expect(gauge).to receive(:set).with(0, labels: { status: 'failed' })

      PrometheusMetrics.send(:refresh_status_gauge, gauge, {})
    end

    it 'sets new counts from the provided hash' do
      allow(PrometheusMetrics).to receive(:sanitized_gauge_labels).with(gauge).and_return([])

      expect(gauge).to receive(:set).with(5, labels: { status: 'success' })
      expect(gauge).to receive(:set).with(2, labels: { status: 'failure' })

      PrometheusMetrics.send(:refresh_status_gauge, gauge, { 'success' => 5, 'failure' => 2 })
    end
  end

  describe '.refresh_connection_pool (private)' do
    let(:pool_stat) { { size: 5, connections: 4, busy: 2, idle: 2, waiting: 0 } }

    before do
      # Stub only stat on the real pool so DatabaseCleaner keeps working
      allow(ActiveRecord::Base.connection_pool).to receive(:stat).and_return(pool_stat)
      allow(PrometheusMetrics::AR_POOL_SIZE).to receive(:set)
      allow(PrometheusMetrics::AR_POOL_CONNECTIONS).to receive(:set)
      allow(PrometheusMetrics::AR_POOL_BUSY).to receive(:set)
      allow(PrometheusMetrics::AR_POOL_IDLE).to receive(:set)
      allow(PrometheusMetrics::AR_POOL_WAITING).to receive(:set)
    end

    it 'sets AR_POOL_SIZE to the pool size' do
      expect(PrometheusMetrics::AR_POOL_SIZE).to receive(:set).with(5)
      PrometheusMetrics.send(:refresh_connection_pool)
    end

    it 'sets AR_POOL_CONNECTIONS to the connection count' do
      expect(PrometheusMetrics::AR_POOL_CONNECTIONS).to receive(:set).with(4)
      PrometheusMetrics.send(:refresh_connection_pool)
    end

    it 'sets AR_POOL_BUSY to the busy count' do
      expect(PrometheusMetrics::AR_POOL_BUSY).to receive(:set).with(2)
      PrometheusMetrics.send(:refresh_connection_pool)
    end

    it 'sets AR_POOL_IDLE to the idle count' do
      expect(PrometheusMetrics::AR_POOL_IDLE).to receive(:set).with(2)
      PrometheusMetrics.send(:refresh_connection_pool)
    end

    it 'sets AR_POOL_WAITING to the waiting count' do
      expect(PrometheusMetrics::AR_POOL_WAITING).to receive(:set).with(0)
      PrometheusMetrics.send(:refresh_connection_pool)
    end
  end

  describe '.refresh_puma (private)' do
    context 'when puma_stats.json has worker_status' do
      let(:stats) do
        {
          workers: 2,
          booted_workers: 2,
          worker_status: [
            { index: 0, last_status: { backlog: 0, running: 2, pool_capacity: 3, max_threads: 5 } },
            { index: 1, last_status: { backlog: 1, running: 1, pool_capacity: 4, max_threads: 5 } }
          ]
        }.to_json
      end

      before do
        allow(File).to receive(:read).with('tmp/puma_stats.json').and_return(stats)
        allow(PrometheusMetrics::PUMA_WORKERS_TOTAL).to receive(:set)
        allow(PrometheusMetrics::PUMA_BOOTED_WORKERS).to receive(:set)
        allow(PrometheusMetrics).to receive(:update_puma_worker)
      end

      it 'sets PUMA_WORKERS_TOTAL' do
        expect(PrometheusMetrics::PUMA_WORKERS_TOTAL).to receive(:set).with(2)
        PrometheusMetrics.send(:refresh_puma)
      end

      it 'sets PUMA_BOOTED_WORKERS' do
        expect(PrometheusMetrics::PUMA_BOOTED_WORKERS).to receive(:set).with(2)
        PrometheusMetrics.send(:refresh_puma)
      end

      it 'calls update_puma_worker for each entry in worker_status' do
        expect(PrometheusMetrics).to receive(:update_puma_worker).twice
        PrometheusMetrics.send(:refresh_puma)
      end
    end

    context 'when puma_stats.json is absent (ENOENT)' do
      before { allow(File).to receive(:read).with('tmp/puma_stats.json').and_raise(Errno::ENOENT) }

      it 'does not raise an error' do
        expect { PrometheusMetrics.send(:refresh_puma) }.not_to raise_error
      end
    end

    context 'when puma_stats.json has no worker_status key' do
      let(:stats) { { other_key: 1 }.to_json }

      before { allow(File).to receive(:read).with('tmp/puma_stats.json').and_return(stats) }

      it 'does not set any puma gauges' do
        expect(PrometheusMetrics::PUMA_WORKERS_TOTAL).not_to receive(:set)
        PrometheusMetrics.send(:refresh_puma)
      end
    end
  end

  describe '.update_puma_worker (private)' do
    let(:worker) do
      { index: 2, last_status: { backlog: 3, running: 4, pool_capacity: 6, max_threads: 10 } }
    end

    before do
      allow(PrometheusMetrics::PUMA_BACKLOG).to receive(:set)
      allow(PrometheusMetrics::PUMA_RUNNING_THREADS).to receive(:set)
      allow(PrometheusMetrics::PUMA_POOL_CAPACITY).to receive(:set)
      allow(PrometheusMetrics::PUMA_MAX_THREADS).to receive(:set)
    end

    it 'sets PUMA_BACKLOG with the worker index label' do
      expect(PrometheusMetrics::PUMA_BACKLOG).to receive(:set).with(3, labels: { worker: '2' })
      PrometheusMetrics.send(:update_puma_worker, worker)
    end

    it 'sets PUMA_RUNNING_THREADS with the worker index label' do
      expect(PrometheusMetrics::PUMA_RUNNING_THREADS).to receive(:set).with(4, labels: { worker: '2' })
      PrometheusMetrics.send(:update_puma_worker, worker)
    end

    it 'sets PUMA_POOL_CAPACITY with the worker index label' do
      expect(PrometheusMetrics::PUMA_POOL_CAPACITY).to receive(:set).with(6, labels: { worker: '2' })
      PrometheusMetrics.send(:update_puma_worker, worker)
    end

    it 'sets PUMA_MAX_THREADS with the worker index label' do
      expect(PrometheusMetrics::PUMA_MAX_THREADS).to receive(:set).with(10, labels: { worker: '2' })
      PrometheusMetrics.send(:update_puma_worker, worker)
    end
  end

  describe '.refresh_ci_domain (private)' do
    let(:ci_job_counts) { { 'queued' => 3, 'failed' => 1 } }
    let(:stage_counts) { { 'success' => 5 } }

    before do
      ci_job_scope = double
      allow(ci_job_scope).to receive(:where).and_return(double(group: double(count: ci_job_counts)))
      allow(CiJob).to receive(:unscoped).and_return(ci_job_scope)

      stage_scope = double
      allow(stage_scope).to receive(:where).and_return(double(group: double(count: stage_counts)))
      allow(Stage).to receive(:unscoped).and_return(stage_scope)

      allow(PrometheusMetrics).to receive(:refresh_status_gauge)
    end

    it 'refreshes CI_JOBS gauge' do
      expect(PrometheusMetrics).to receive(:refresh_status_gauge)
        .with(PrometheusMetrics::CI_JOBS, ci_job_counts)
      PrometheusMetrics.send(:refresh_ci_domain)
    end

    it 'refreshes CI_STAGES gauge' do
      expect(PrometheusMetrics).to receive(:refresh_status_gauge)
        .with(PrometheusMetrics::CI_STAGES, stage_counts)
      PrometheusMetrics.send(:refresh_ci_domain)
    end
  end

  describe '.dj_active_counts (private)' do
    let(:now) { Time.now }

    before do
      allow(Delayed::Job).to receive(:where).and_return(double(group: double(count: {})))
    end

    it 'returns a hash with :pending, :running, and :scheduled keys' do
      result = PrometheusMetrics.send(:dj_active_counts, now)
      expect(result.keys).to contain_exactly(:pending, :running, :scheduled)
    end
  end

  describe '.dj_problem_counts (private)' do
    let(:now) { Time.now }

    before do
      allow(Delayed::Job).to receive(:where).and_return(double(group: double(count: {})))
    end

    it 'returns a hash with :failed, :max_att, and :stuck keys' do
      result = PrometheusMetrics.send(:dj_problem_counts, now)
      expect(result.keys).to contain_exactly(:failed, :max_att, :stuck)
    end
  end

  describe '.set_dj_queue_gauges (private)' do
    let(:counts) do
      {
        pending:  { 'default' => 2, 'ci' => 1 },
        running:  { 'default' => 0 },
        scheduled: {},
        failed:   {},
        max_att:  {},
        stuck:    {}
      }
    end

    before do
      PrometheusMetrics::GAUGE_COUNT_MAP.each_key { |g| allow(g).to receive(:set) }
    end

    it 'sets the pending gauge for the given queue' do
      expect(PrometheusMetrics::DJ_PENDING).to receive(:set).with(2, labels: { queue: 'default' })
      PrometheusMetrics.send(:set_dj_queue_gauges, 'default', counts)
    end

    it 'defaults to 0 when the queue is not present in a count category' do
      expect(PrometheusMetrics::DJ_SCHEDULED).to receive(:set).with(0, labels: { queue: 'default' })
      PrometheusMetrics.send(:set_dj_queue_gauges, 'default', counts)
    end
  end

  describe '.record_scheduled_job (private)' do
    let(:run_at) { Time.now + 60 }
    let(:job) do
      double(
        id: 42,
        queue: 'default',
        handler: "--- !ruby/object:MyWorker\nmethod_name: :process\nargs:\n",
        run_at: run_at
      )
    end

    before { allow(PrometheusMetrics::DJ_TABLE).to receive(:set) }

    it 'sets DJ_TABLE with the job unix timestamp' do
      expect(PrometheusMetrics::DJ_TABLE).to receive(:set).with(
        run_at.to_i,
        labels: hash_including(job_id: '42', queue: 'default')
      )
      PrometheusMetrics.send(:record_scheduled_job, job)
    end

    it 'includes job_class and job_args in the labels' do
      expect(PrometheusMetrics::DJ_TABLE).to receive(:set).with(
        anything,
        labels: hash_including(:job_class, :job_args)
      )
      PrometheusMetrics.send(:record_scheduled_job, job)
    end
  end

  describe '.refresh_delayed_jobs (private)' do
    before do
      allow(PrometheusMetrics).to receive(:reset_dj_gauges)
      allow(PrometheusMetrics).to receive(:dj_active_counts).and_return(
        pending: { 'default' => 1 }, running: {}, scheduled: {}
      )
      allow(PrometheusMetrics).to receive(:dj_problem_counts).and_return(
        failed: {}, max_att: {}, stuck: {}
      )
      allow(PrometheusMetrics).to receive(:set_dj_queue_gauges)
    end

    it 'resets gauges before updating' do
      expect(PrometheusMetrics).to receive(:reset_dj_gauges).ordered
      expect(PrometheusMetrics).to receive(:dj_active_counts).ordered
      PrometheusMetrics.send(:refresh_delayed_jobs)
    end

    it 'calls set_dj_queue_gauges for each unique queue found' do
      expect(PrometheusMetrics).to receive(:set_dj_queue_gauges).with('default', anything)
      PrometheusMetrics.send(:refresh_delayed_jobs)
    end

    it 'only calls set_dj_queue_gauges once when the same queue appears in multiple counts' do
      allow(PrometheusMetrics).to receive(:dj_active_counts).and_return(
        pending: { 'default' => 2 }, running: { 'default' => 1 }, scheduled: {}
      )
      expect(PrometheusMetrics).to receive(:set_dj_queue_gauges).once
      PrometheusMetrics.send(:refresh_delayed_jobs)
    end
  end

  describe '.refresh_scheduled_jobs_detail (private)' do
    let(:now) { Time.now }
    let(:job) do
      double(
        id: 10,
        queue: 'ci',
        handler: "--- !ruby/object:CiWorker\nmethod_name: :run\nargs:\n",
        run_at: now + 300
      )
    end

    before do
      allow(PrometheusMetrics).to receive(:sanitized_gauge_labels).with(PrometheusMetrics::DJ_TABLE)
        .and_return([])
      allow(PrometheusMetrics::DJ_TABLE).to receive(:set)

      where_result = double
      allow(where_result).to receive(:select).and_return([job])
      allow(Delayed::Job).to receive(:where).and_return(where_result)

      allow(PrometheusMetrics).to receive(:record_scheduled_job)
    end

    it 'calls record_scheduled_job for each upcoming job' do
      expect(PrometheusMetrics).to receive(:record_scheduled_job).with(job)
      PrometheusMetrics.send(:refresh_scheduled_jobs_detail)
    end
  end
end