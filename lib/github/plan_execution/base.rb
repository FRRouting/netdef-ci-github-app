#  SPDX-License-Identifier: BSD-2-Clause
#
#  base.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

#  SPDX-License-Identifier: BSD-2-Clause
#
#  base.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'logger'
require_relative '../../bamboo_ci/api'

module Github
  module PlanExecution
    class Base
      include BambooCi::Api

      def fetch_ci_execution
        @result = get_status(@check_suite.bamboo_ci_ref)
      end

      def fetch_build_status
        get_request(URI("https://127.0.0.1/rest/api/latest/result/status/#{@check_suite.bamboo_ci_ref}"))
      end
    end
  end
end
