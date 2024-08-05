#  SPDX-License-Identifier: BSD-2-Clause
#
#  database_loader.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'active_record'
require 'otr-activerecord'

module OTR
  module ActiveRecord
    class << self
      alias original_configure_from_file! configure_from_file!

      def configure_from_file!(file)
        config = YAML.safe_load_file(file, permitted_classes: [Symbol], aliases: true)
        ::ActiveRecord::Base.configurations = config
      end
    end
  end
end

OTR::ActiveRecord.db_dir = 'db'
OTR::ActiveRecord.migrations_paths = ['db/migrate']
OTR::ActiveRecord.configure_from_file! 'config/database.yml'
ActiveRecord::Base.logger&.level = Logger::WARN

Dir['lib/models/*.rb'].each { |model| require_relative model }

OTR::ActiveRecord.establish_connection!
