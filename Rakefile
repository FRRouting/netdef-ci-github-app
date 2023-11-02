#  SPDX-License-Identifier: BSD-2-Clause
#
#  Rakefile
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'bundler/setup'
require 'otr-activerecord'

load 'tasks/otr-activerecord.rake'

namespace :db do
  # Some db tasks require your app code to be loaded; they'll expect to find it here
  task :environment do
    require_relative 'database_loader'
  end
end
