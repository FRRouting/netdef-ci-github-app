#  SPDX-License-Identifier: BSD-2-Clause
#
#  telemetry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'singleton'
require 'json'

class Telemetry
  include Singleton

  def update_stats(stats)
    File.write('telemetry.json', stats.to_json)
  end
  
  def stats
    JSON.parse(File.read('telemetry.json'))
  end
end
