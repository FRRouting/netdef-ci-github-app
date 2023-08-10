# frozen_string_literal: true

require 'otr-activerecord'

OTR::ActiveRecord.db_dir = 'db'
OTR::ActiveRecord.migrations_paths = ['db/migrate']
OTR::ActiveRecord.configure_from_file! 'config/database.yml'

Dir['lib/models/*.rb'].each { |model| require_relative model }

OTR::ActiveRecord.establish_connection!
