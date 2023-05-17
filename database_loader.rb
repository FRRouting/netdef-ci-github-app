# frozen_string_literal: true

require 'otr-activerecord'

require_relative 'lib/models/*'

OTR::ActiveRecord.configure_from_hash!(adapter: 'postgresql',
                                       host: 'localhost',
                                       database: 'github-hook',
                                       username: 'postgres',
                                       password: 'postgres',
                                       encoding: 'utf8',
                                       pool: 10,
                                       timeout: 5000)

OTR::ActiveRecord.establish_connection!
