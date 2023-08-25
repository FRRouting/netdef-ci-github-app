#  SPDX-License-Identifier: BSD-2-Clause
#
#  sidekiq.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'sidekiq'
require 'yaml'
config_yaml = GitHubApp::Configuration.instance.config

Sidekiq.configure_server do |config|
  config.redis = { url: "redis://#{config_yaml.dig('redis', 'host')}:#{config_yaml.dig('redis', 'port')}" }
end

Sidekiq.configure_client do |config|
  config.redis = { url: "redis://#{config_yaml.dig('redis', 'host')}:#{config_yaml.dig('redis', 'port')}" }
end
