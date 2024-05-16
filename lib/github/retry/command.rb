#  SPDX-License-Identifier: BSD-2-Clause
#
#  command.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#

require_relative 'base'

module Github
  module Retry
    class Command < Base
      def initialize(payload, logger_level: Logger::INFO)
        super(payload)

        create_logger(logger_level)

        @payload = payload

        @stage = Stage.find_by_check_ref(@payload.dig('check_run', 'id'))
      end
    end
  end
end
