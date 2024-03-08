#  SPDX-License-Identifier: BSD-2-Clause
#
#  company.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class Company < ActiveRecord::Base
  has_many :users
end
