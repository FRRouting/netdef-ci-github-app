# frozen_string_literal: true

require 'sidekiq'
require 'yaml'

config_yaml = GithubApp.configuration

Sidekiq.configure_server do |config|
  config.redis = { url: "redis://#{config_yaml.dig('redis', 'host')}:#{config_yaml.dig('redis', 'port')}" }
end

Sidekiq.configure_client do |config|
  config.redis = { url: "redis://#{config_yaml.dig('redis', 'host')}:#{config_yaml.dig('redis', 'port')}" }
end
