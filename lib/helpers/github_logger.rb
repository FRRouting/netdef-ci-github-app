#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_logger.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require 'singleton'
require 'fileutils'

class GithubLogger
  include Singleton

  def create(name, logger_level)
    FileUtils.mkdir_p File.expand_path('./logs')
    obj = Logger.new("logs/#{name}", 2, 524_288_000)
    obj.level = logger_level

    obj
  end
end
