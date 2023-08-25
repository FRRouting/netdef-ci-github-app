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

File.write('.session.key', SecureRandom.hex(32))

use Rack::Session::Cookie, secret: File.read('.session.key'), same_site: true, max_age: 86_400

Rack::Handler::Puma.run Rack::URLMap.new('/' => GithubApp)

exit 0
