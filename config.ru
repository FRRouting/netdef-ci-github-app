#  SPDX-License-Identifier: BSD-2-Clause
#
#  config.ru
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require_relative 'app/github_app'
require_relative 'config/sidekiq'

require 'puma'
require 'rack/handler/puma'
require 'rack/session/cookie'

require 'sidekiq'
require 'sidekiq/web'

require 'rack/protection'
require "rack/attack"

use Rack::Attack
use Rack::Protection

File.write('.session.key', SecureRandom.hex(32))

use Rack::Session::Cookie, secret: File.read('.session.key'), same_site: true, max_age: 86_400

# 100 requests/minute
Rack::Attack.throttle("requests by ip", limit: 100, period: 60) do |request|
  request.ip
end

@logger_attack = Logger.new('rack_attack.log', 1, 1_024_000)
Rack::Attack.throttled_response = lambda do |env|
  @logger_attack.warn("Detected attack: #{env.inspect}")
  [ 503, {}, ["Server Error\n"]]
end

Rack::Handler::Puma.run Rack::URLMap.new('/' => GithubApp)

exit 0
