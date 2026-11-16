#  SPDX-License-Identifier: BSD-2-Clause
#
#  configuration.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'singleton'
require 'yaml'
module GitHubApp
  class Configuration
    include Singleton

    DEFAULT_BAMBOO_OAUTH_SCOPE = 'READ TRIGGER WRITE'

    attr_reader :config

    def initialize
      configuration
    end

    def reload
      configuration
    end

    def debug?
      config.key? 'debug' and config['debug']
    end

    def multi_plan?
      config.key? 'multi_plan?' and config['multi_plan?']
    end

    def ci_url
      return @config['ci']['url'] if @config.key?('ci') && @config['ci'].key?('url')

      'https://ci1.netdef.org'
    end

    # Bamboo 12 service account (OAuth 2.0 client credentials): [client_id, client_secret] when both are set.
    # The environment (BAMBOO_CLIENT_ID / BAMBOO_CLIENT_SECRET) wins over config.yml (bamboo.client_id / client_secret).
    def bamboo_service_account
      client_id = bamboo_setting('BAMBOO_CLIENT_ID', 'client_id')
      secret = bamboo_setting('BAMBOO_CLIENT_SECRET', 'client_secret')

      client_id.empty? || secret.empty? ? nil : [client_id, secret]
    end

    # Bamboo 12 refuses a token request without a scope; each API needs its own (READ, TRIGGER, WRITE).
    # An empty value (set explicitly) means the scope is not sent.
    def bamboo_oauth_scope
      default = bamboo_config.fetch('oauth_scope', DEFAULT_BAMBOO_OAUTH_SCOPE)
      scope = ENV.fetch('BAMBOO_OAUTH_SCOPE', default).to_s.strip

      scope.empty? ? nil : scope
    end

    private

    def bamboo_config
      @config.is_a?(Hash) && @config['bamboo'].is_a?(Hash) ? @config['bamboo'] : {}
    end

    def bamboo_setting(env_name, key)
      value = ENV.fetch(env_name, '').strip
      value.empty? ? bamboo_config[key].to_s.strip : value
    end

    def configuration
      path = File.expand_path('config.yml', "#{File.dirname(__FILE__)}/../..")
      @config = YAML.load_file(path)
    end
  end
end
