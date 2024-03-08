#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

module Github
  module Build
    class Plan
      def initialize(user)
        @user = user
      end
    end
  end
end
