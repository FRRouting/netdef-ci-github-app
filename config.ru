# frozen_string_literal: true

require_relative 'config/environment'
require_relative 'app/github_app'

require 'puma'
require 'rack/handler/puma'

set :port, 4667

begin
  run GithubApp.new
rescue ArgumentError
  run GithubApp
end

Rack::Handler::Puma.run GithubApp

exit 0
