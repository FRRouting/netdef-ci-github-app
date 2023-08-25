#  SPDX-License-Identifier: BSD-2-Clause
#
#  .simplecov
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

SimpleCov.start do
  enable_coverage :branch
  primary_coverage :branch
  add_filter %r{^/spec/}
  add_group 'Models', 'lib/models'
  add_group 'GitHub Functions', 'lib/github'
  add_group 'Bamboo CI Functions', 'lib/bamboo_ci'
  add_group 'Helpers', 'lib/helpers'
  add_group 'Others', %w[app/ database_loader.rb]

  minimum_coverage_by_file line: 90, branch: 90
end
