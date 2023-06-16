# frozen_string_literal: true

require_relative 'config/environment'
require_relative 'app/github_app'

set :port, 4667

run GithubApp.new
