#  SPDX-License-Identifier: BSD-2-Clause
#
#  request_metrics_spec.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

describe RequestMetrics do
  let(:status) { 200 }
  let(:route) { 'POST /*' }
  let(:error) { nil }
  let(:inner_app) do
    lambda do |env|
      env['sinatra.route'] = route unless route.nil?
      env['sinatra.error'] = error unless error.nil?
      [status, {}, ['ok']]
    end
  end
  let(:middleware) { described_class.new(inner_app) }
  let(:env) { { 'REQUEST_METHOD' => 'POST', 'HTTP_X_GITHUB_EVENT' => 'pull_request' } }

  before do
    allow(PrometheusMetrics::HTTP_REQUESTS).to receive(:increment)
    allow(PrometheusMetrics::HTTP_REQUEST_DURATION).to receive(:observe)
    allow(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS).to receive(:increment)
    allow(PrometheusMetrics::APP_EXCEPTIONS).to receive(:increment)
  end

  it 'records the request under its route pattern' do
    expect(middleware.call(env)).to eq([200, {}, ['ok']])

    expect(PrometheusMetrics::HTTP_REQUESTS)
      .to have_received(:increment).with(labels: { method: 'POST', path: '/*', status: '200' })
    expect(PrometheusMetrics::HTTP_REQUEST_DURATION)
      .to have_received(:observe).with(kind_of(Float), labels: { path: '/*' })
    expect(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS)
      .to have_received(:increment).with(labels: { event: 'pull_request', result: 'processed' })
    expect(PrometheusMetrics::APP_EXCEPTIONS).not_to have_received(:increment)
  end

  context 'when no route matched' do
    let(:route) { nil }
    let(:status) { 404 }
    let(:env) { { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/wp-login.php' } }

    it 'records it under a fixed label instead of the path' do
      middleware.call(env)

      expect(PrometheusMetrics::HTTP_REQUESTS)
        .to have_received(:increment).with(labels: { method: 'GET', path: 'unmatched', status: '404' })
      expect(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS).not_to have_received(:increment)
    end
  end

  context 'when the HTTP method is unknown' do
    let(:env) { { 'REQUEST_METHOD' => 'FOO1' } }

    it 'records it as other' do
      middleware.call(env)

      expect(PrometheusMetrics::HTTP_REQUESTS)
        .to have_received(:increment).with(labels: { method: 'other', path: '/*', status: '200' })
    end
  end

  context 'when a request outside the webhook route carries a GitHub event header' do
    let(:route) { 'POST /slack' }

    it 'is not counted as a webhook event' do
      middleware.call(env)

      expect(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS).not_to have_received(:increment)
    end
  end

  context 'when recording the metrics fails' do
    before { allow(PrometheusMetrics::HTTP_REQUEST_DURATION).to receive(:observe).and_raise(ArgumentError, 'labels') }

    it 'returns the response untouched and counts no exception' do
      expect(middleware.call(env)).to eq([200, {}, ['ok']])

      expect(PrometheusMetrics::HTTP_REQUESTS).to have_received(:increment).once
      expect(PrometheusMetrics::APP_EXCEPTIONS).not_to have_received(:increment)
    end
  end

  context 'when the GitHub event header is unknown' do
    let(:env) { { 'REQUEST_METHOD' => 'POST', 'HTTP_X_GITHUB_EVENT' => 'made-up-event' } }

    it 'records it as other' do
      middleware.call(env)

      expect(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS)
        .to have_received(:increment).with(labels: { event: 'other', result: 'processed' })
    end
  end

  context 'when the app handled an exception as a server error' do
    let(:status) { 500 }
    let(:error) { ArgumentError.new('boom') }

    it 'records the exception under the route' do
      middleware.call(env)

      expect(PrometheusMetrics::APP_EXCEPTIONS)
        .to have_received(:increment).with(labels: { class: 'ArgumentError', handler: '/*' })
      expect(PrometheusMetrics::GITHUB_WEBHOOK_EVENTS)
        .to have_received(:increment).with(labels: { event: 'pull_request', result: 'error' })
    end
  end

  context 'when the app raises' do
    let(:inner_app) { ->(_env) { raise ArgumentError, 'boom' } }

    it 'records a server error and raises again' do
      expect { middleware.call(env) }.to raise_error(ArgumentError, 'boom')

      expect(PrometheusMetrics::HTTP_REQUESTS)
        .to have_received(:increment).with(labels: { method: 'POST', path: 'unmatched', status: '500' })
      expect(PrometheusMetrics::APP_EXCEPTIONS)
        .to have_received(:increment).with(labels: { class: 'ArgumentError', handler: 'unmatched' })
    end
  end
end
