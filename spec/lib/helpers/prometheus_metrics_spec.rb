#  SPDX-License-Identifier: BSD-2-Clause
#
#  prometheus_metrics_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe PrometheusMetrics do
  describe '.track_bamboo' do
    context 'when the block succeeds with an HTTP response' do
      let(:result) { double(code: '200') }

      it 'returns the result' do
        allow(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
        allow(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)

        returned = PrometheusMetrics.track_bamboo('plan_run') { result }
        expect(returned).to eq(result)
      end

      it 'increments BAMBOO_REQUESTS with success status' do
        expect(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
          .with(labels: { operation: 'plan_run', status: 'success' })
        allow(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)

        PrometheusMetrics.track_bamboo('plan_run') { result }
      end

      it 'observes BAMBOO_DURATION' do
        allow(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
        expect(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)
          .with(a_kind_of(Numeric), labels: { operation: 'plan_run' })

        PrometheusMetrics.track_bamboo('plan_run') { result }
      end
    end

    context 'when the block returns nil' do
      it 'increments BAMBOO_REQUESTS with error status and returns nil' do
        expect(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
          .with(labels: { operation: 'result', status: 'error' })
        allow(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)

        expect(PrometheusMetrics.track_bamboo('result') { nil }).to be_nil
      end
    end

    context 'when the block returns a 4xx response' do
      let(:result) { double(code: '404') }

      it 'increments BAMBOO_REQUESTS with error status' do
        expect(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
          .with(labels: { operation: 'plan_run', status: 'error' })
        allow(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)

        PrometheusMetrics.track_bamboo('plan_run') { result }
      end
    end

    context 'when the block raises a StandardError' do
      it 'increments BAMBOO_REQUESTS with error status and returns nil' do
        expect(PrometheusMetrics::BAMBOO_REQUESTS).to receive(:increment)
          .with(labels: { operation: 'plan_run', status: 'error' })
        allow(PrometheusMetrics::BAMBOO_DURATION).to receive(:observe)

        returned = PrometheusMetrics.track_bamboo('plan_run') { raise StandardError, 'network error' }
        expect(returned).to be_nil
      end
    end
  end

  describe '.track_slack' do
    context 'when the block returns a non-nil value' do
      it 'increments SLACK_NOTIFICATIONS with sent status and returns the value' do
        expect(PrometheusMetrics::SLACK_NOTIFICATIONS).to receive(:increment)
          .with(labels: { type: 'failure', status: 'sent' })

        result = PrometheusMetrics.track_slack('failure') { 'ok' }
        expect(result).to eq('ok')
      end
    end

    context 'when the block returns nil' do
      it 'increments SLACK_NOTIFICATIONS with error status' do
        expect(PrometheusMetrics::SLACK_NOTIFICATIONS).to receive(:increment)
          .with(labels: { type: 'failure', status: 'error' })

        PrometheusMetrics.track_slack('failure') { nil }
      end
    end

    context 'when the block raises a StandardError' do
      it 'increments SLACK_NOTIFICATIONS with error status and returns nil' do
        expect(PrometheusMetrics::SLACK_NOTIFICATIONS).to receive(:increment)
          .with(labels: { type: 'alert', status: 'error' })

        result = PrometheusMetrics.track_slack('alert') { raise StandardError }
        expect(result).to be_nil
      end
    end
  end

  describe '.cleanup_stale_metric_files!' do
    let(:metrics_dir) { PrometheusMetrics::METRICS_DIR }

    context 'when a metric file belongs to a dead process' do
      let(:dead_pid) { 99_998 }
      let(:dead_file) { File.join(metrics_dir, "metric_test___#{dead_pid}.bin") }

      before { FileUtils.touch(dead_file) }
      after  { File.delete(dead_file) if File.exist?(dead_file) }

      it 'deletes the stale file' do
        # default all other pids to alive; only the dead one returns false
        allow(PrometheusMetrics).to receive(:process_alive?).and_return(true)
        allow(PrometheusMetrics).to receive(:process_alive?).with(dead_pid).and_return(false)
        PrometheusMetrics.cleanup_stale_metric_files!
        expect(File.exist?(dead_file)).to be false
      end
    end

    context 'when a metric file belongs to the current process' do
      let(:own_file) { File.join(metrics_dir, "metric_test___#{Process.pid}.bin") }

      before { FileUtils.touch(own_file) }
      after  { File.delete(own_file) if File.exist?(own_file) }

      it 'does not delete the file' do
        PrometheusMetrics.cleanup_stale_metric_files!
        expect(File.exist?(own_file)).to be true
      end
    end

    context 'when a metric file belongs to an alive process' do
      let(:live_pid) { 12_345 }
      let(:live_file) { File.join(metrics_dir, "metric_test___#{live_pid}.bin") }

      before { FileUtils.touch(live_file) }
      after  { File.delete(live_file) if File.exist?(live_file) }

      it 'does not delete the file' do
        allow(PrometheusMetrics).to receive(:process_alive?).and_return(true)
        PrometheusMetrics.cleanup_stale_metric_files!
        expect(File.exist?(live_file)).to be true
      end
    end

    context 'when Dir.glob raises a StandardError' do
      it 'warns and does not raise' do
        allow(Dir).to receive(:glob).and_raise(StandardError, 'glob error')
        expect { PrometheusMetrics.cleanup_stale_metric_files! }.not_to raise_error
      end
    end
  end

  describe '.refresh!' do
    before do
      allow(PrometheusMetrics).to receive(:refresh_delayed_jobs)
      allow(PrometheusMetrics).to receive(:refresh_scheduled_jobs_detail)
      allow(PrometheusMetrics).to receive(:refresh_ci_domain)
      allow(PrometheusMetrics).to receive(:refresh_connection_pool)
      allow(PrometheusMetrics).to receive(:refresh_puma)
    end

    it 'calls all refresh sub-methods' do
      expect(PrometheusMetrics).to receive(:refresh_delayed_jobs)
      expect(PrometheusMetrics).to receive(:refresh_scheduled_jobs_detail)
      expect(PrometheusMetrics).to receive(:refresh_ci_domain)
      expect(PrometheusMetrics).to receive(:refresh_connection_pool)
      expect(PrometheusMetrics).to receive(:refresh_puma)

      PrometheusMetrics.refresh!
    end

    context 'when a sub-method raises a StandardError' do
      before { allow(PrometheusMetrics).to receive(:refresh_delayed_jobs).and_raise(StandardError, 'db error') }

      it 'warns and does not propagate the error' do
        expect { PrometheusMetrics.refresh! }.not_to raise_error
      end
    end
  end

  describe '.bamboo_response_status (private)' do
    subject(:status) { PrometheusMetrics.send(:bamboo_response_status, result) }

    context 'when result is nil' do
      let(:result) { nil }

      it { is_expected.to eq('error') }
    end

    context 'when result has no code method' do
      let(:result) { 'plain string' }

      it { is_expected.to eq('success') }
    end

    context 'when result has a 2xx code' do
      let(:result) { double(code: '200') }

      it { is_expected.to eq('success') }
    end

    context 'when result has a 4xx code' do
      let(:result) { double(code: '404') }

      it { is_expected.to eq('error') }
    end

    context 'when result has a 5xx code' do
      let(:result) { double(code: '500') }

      it { is_expected.to eq('error') }
    end

    context 'when result has a 399 code (boundary below error)' do
      let(:result) { double(code: '399') }

      it { is_expected.to eq('success') }
    end

    context 'when result has a 400 code (boundary at error)' do
      let(:result) { double(code: '400') }

      it { is_expected.to eq('error') }
    end
  end

  describe '.process_alive? (private)' do
    subject(:alive?) { PrometheusMetrics.send(:process_alive?, pid) }

    context 'when the process exists and responds to signal 0' do
      let(:pid) { Process.pid }

      it { is_expected.to be true }
    end

    context 'when the process does not exist (ESRCH)' do
      let(:pid) { 99_997 }

      before { allow(Process).to receive(:kill).with(0, pid).and_raise(Errno::ESRCH) }

      it { is_expected.to be false }
    end

    context 'when the process exists but we lack permission (EPERM)' do
      let(:pid) { 1 }

      before { allow(Process).to receive(:kill).with(0, pid).and_raise(Errno::EPERM) }

      it { is_expected.to be true }
    end
  end

  describe '.extract_sql_operation (private)' do
    subject(:op) { PrometheusMetrics.send(:extract_sql_operation, sql) }

    context 'with a SELECT statement' do
      let(:sql) { 'SELECT * FROM users' }

      it { is_expected.to eq('SELECT') }
    end

    context 'with an INSERT statement' do
      let(:sql) { 'INSERT INTO users (name) VALUES ("foo")' }

      it { is_expected.to eq('INSERT') }
    end

    context 'with an UPDATE statement' do
      let(:sql) { 'UPDATE users SET name = "bar" WHERE id = 1' }

      it { is_expected.to eq('UPDATE') }
    end

    context 'with a DELETE statement' do
      let(:sql) { 'DELETE FROM users WHERE id = 1' }

      it { is_expected.to eq('DELETE') }
    end

    context 'with a BEGIN statement (not tracked)' do
      let(:sql) { 'BEGIN' }

      it { is_expected.to be_nil }
    end

    context 'with a COMMIT statement (not tracked)' do
      let(:sql) { 'COMMIT' }

      it { is_expected.to be_nil }
    end

    context 'with nil input' do
      let(:sql) { nil }

      it { is_expected.to be_nil }
    end

    context 'with an empty string' do
      let(:sql) { '' }

      it { is_expected.to be_nil }
    end

    context 'with lowercase select' do
      let(:sql) { 'select id from ci_jobs' }

      it { is_expected.to eq('SELECT') }
    end
  end

  describe '.extract_table_name (private)' do
    subject(:table) { PrometheusMetrics.send(:extract_table_name, name) }

    context 'with a standard model name' do
      let(:name) { 'User Load' }

      it { is_expected.to eq('user') }
    end

    context 'with a namespaced model name' do
      let(:name) { 'BambooCi::Result Load' }

      it { is_expected.to eq('bambooci_result') }
    end

    context 'with SCHEMA' do
      let(:name) { 'SCHEMA' }

      it { is_expected.to eq('other') }
    end

    context 'with EXPLAIN' do
      let(:name) { 'EXPLAIN' }

      it { is_expected.to eq('other') }
    end

    context 'with TRANSACTION' do
      let(:name) { 'TRANSACTION' }

      it { is_expected.to eq('other') }
    end

    context 'with nil input' do
      let(:name) { nil }

      it { is_expected.to eq('unknown') }
    end

    context 'with an empty string' do
      let(:name) { '' }

      it { is_expected.to eq('unknown') }
    end
  end
end