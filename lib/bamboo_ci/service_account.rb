#  SPDX-License-Identifier: BSD-2-Clause
#
#  service_account.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2026 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'json'
require 'logger'
require 'net/http'
require 'net/https'
require 'singleton'
require 'uri'

require_relative '../helpers/configuration'
require_relative '../helpers/github_logger'

module BambooCi
  # Bamboo 12 service account: OAuth 2.0 client credentials (2LO) with a cached Bearer token.
  # The token is shared by every request of the process and replaced shortly before Bamboo says it expires.
  class ServiceAccount
    include Singleton

    TOKEN_PATH = '/rest/oauth2/latest/token'
    TOKEN_REFRESH_MARGIN_SECONDS = 60
    DEFAULT_TOKEN_LIFETIME_SECONDS = 3600

    attr_reader :granted_scope, :last_error

    def initialize
      @mutex = Mutex.new
      reset
    end

    def configured?
      !credentials.nil?
    end

    # Cached token, or a new one from the Bamboo that answers `uri`. Returns [token, fresh] (token nil on failure).
    def token_for(uri)
      cached = cached_token
      return [cached, false] unless cached.nil?

      [fetch_token(uri), true]
    end

    # Drops a token Bamboo refused (revoked, Bamboo restarted), unless another thread already replaced it.
    def forget(token)
      @mutex.synchronize { @token = nil if @token == token }
    end

    def reset
      @mutex.synchronize do
        @token = nil
        @expires_at = 0.0
      end
      @granted_scope = nil
      @last_error = nil
    end

    def scope
      GitHubApp::Configuration.instance.bamboo_oauth_scope
    end

    private

    def credentials
      GitHubApp::Configuration.instance.bamboo_service_account
    end

    def cached_token
      @mutex.synchronize { @token if !@token.nil? && now < @expires_at }
    end

    def fetch_token(uri)
      response = request_token(uri)
      body = parse_body(response)
      token = body['access_token']

      return token_failed(response) unless token.is_a?(String) && !token.empty?

      store_token(token, body)
    rescue StandardError => e
      @last_error = "#{e.class}: #{e.message}"
      logger.error { "Bamboo service account token request failed (requested scope: #{scope || '-'}): #{@last_error}" }

      nil
    end

    def request_token(uri)
      token_uri = URI::HTTPS.build(host: uri.host, port: uri.port, path: TOKEN_PATH)
      req = Net::HTTP::Post.new(token_uri)
      req.set_form_data(token_form)
      req['Accept'] = 'application/json'

      http = Net::HTTP.new(token_uri.host, token_uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.request(req)
    end

    def token_form
      client_id, client_secret = credentials
      form = { 'grant_type' => 'client_credentials', 'client_id' => client_id, 'client_secret' => client_secret }
      form['scope'] = scope unless scope.nil?

      form
    end

    def parse_body(response)
      return {} unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body.to_s)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    # The body is Bamboo's error description; it never carries the secret, which only goes in the request.
    def token_failed(response)
      @last_error = "HTTP #{response.code} #{self.class.summary(response)}"
      logger.error { "Bamboo service account token request failed (requested scope: #{scope || '-'}): #{@last_error}" }

      nil
    end

    def store_token(token, body)
      lifetime = Float(body['expires_in'] || DEFAULT_TOKEN_LIFETIME_SECONDS, exception: false)
      lifetime ||= DEFAULT_TOKEN_LIFETIME_SECONDS

      @mutex.synchronize do
        @token = token
        @expires_at = now + [lifetime - TOKEN_REFRESH_MARGIN_SECONDS, 0].max
      end
      @granted_scope = body['scope'].is_a?(String) ? body['scope'] : nil
      @last_error = nil

      log_token_obtained(lifetime)

      token
    end

    def log_token_obtained(lifetime)
      logger.info do
        "Bamboo service account token obtained (requested scope: #{scope || '-'}; " \
          "granted scope: #{@granted_scope || '-'}; expires in #{lifetime.to_i}s)"
      end

      return if @granted_scope.nil?

      missing = scope_set(scope) - scope_set(@granted_scope)
      return if missing.empty?

      logger.warn do
        "Bamboo did not grant the scopes #{missing.sort.join(' ')}: add them to the service account credential"
      end
    end

    def scope_set(value)
      value.to_s.split(/[\s,]+/).reject(&:empty?)
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def logger
      @logger ||= GithubLogger.instance.create('github_app.log', Logger::INFO)
    end

    class << self
      # Short, readable reason from a Bamboo answer: the JSON message / error_description, the <title> of an HTML
      # error page (Tomcat answers a rejected token with one), or the start of the body.
      def summary(response, limit: 300)
        text = response.body.to_s

        json_message(text) || html_title(text) || text.split.join(' ')[0, limit].then do |start|
          start.empty? ? '(empty body)' : start
        end
      end

      private

      def json_message(text)
        body = JSON.parse(text)
        return nil unless body.is_a?(Hash)

        %w[message error_description error].map { |key| body[key] }.find { |v| v.is_a?(String) && !v.empty? }
      rescue JSON::ParserError
        nil
      end

      def html_title(text)
        match = text.match(%r{<title[^>]*>(.*?)</title>}im)

        match.nil? ? nil : "HTML page: #{match[1].strip}"
      end
    end
  end
end
