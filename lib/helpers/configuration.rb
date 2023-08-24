# frozen_string_literal: true

require 'singleton'
require 'yaml'

class Configuration
  include Singleton

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

  private

  def configuration
    path = File.expand_path('config.yml', "#{File.dirname(__FILE__)}/../..")

    @config = YAML.load_file(path)
  end
end
