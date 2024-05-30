#  SPDX-License-Identifier: BSD-2-Clause
#
#  database_loader.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

OTR::ActiveRecord.db_dir = 'db'
OTR::ActiveRecord.migrations_paths = ['db/migrate']
OTR::ActiveRecord.configure_from_file! 'config/database.yml'
ActiveRecord::Base.logger.level = Logger::WARN

Dir['lib/models/*.rb'].each { |model| require_relative model }

OTR::ActiveRecord.establish_connection!
