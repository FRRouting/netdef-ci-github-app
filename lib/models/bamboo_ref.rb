# frozen_string_literal: true

#   SPDX-License-Identifier: BSD-2-Clause
#
#   bamboo_ref.rb
#   Part of NetDEF CI System
#
#   Copyright (c) 2025 by
#   Network Device Education Foundation, Inc. ("NetDEF")
#
#   frozen_string_literal: true
#

class BambooRef < ActiveRecord::Base
  validates :bamboo_key, presence: true, uniqueness: true
  validates :check_suite, presence: true

  belongs_to :check_suite
  belongs_to :plan
end
