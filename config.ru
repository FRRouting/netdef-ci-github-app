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
require_relative 'config/delayed_job'

require 'puma'
require 'rack/handler/puma'
require 'rack/session/cookie'

File.write('.session.key', SecureRandom.hex(32))

pids = []
pids << spawn("RACK_ENV=#{ENV.fetch('RACK_ENV', 'development')} rake jobs:work MIN_PRIORITY=0 MAX_PRIORITY=3")
pids << spawn("RACK_ENV=#{ENV.fetch('RACK_ENV', 'development')} rake jobs:work MIN_PRIORITY=4 MAX_PRIORITY=6")
pids << spawn("RACK_ENV=#{ENV.fetch('RACK_ENV', 'development')} rake jobs:work MIN_PRIORITY=7 MAX_PRIORITY=9")

use Rack::Session::Cookie, secret: File.read('.session.key'), same_site: true, max_age: 86_400

Rack::Handler::Puma.run Rack::URLMap.new('/' => GithubApp)

pids.each { |pid| Process.kill('TERM', pid.to_i) }

exit 0
