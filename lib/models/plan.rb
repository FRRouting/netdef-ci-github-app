#  SPDX-License-Identifier: BSD-2-Clause
#
#  plan.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class Plan < ActiveRecord::Base
  has_many :check_suites

  belongs_to :pull_request
end
