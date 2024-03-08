#  SPDX-License-Identifier: BSD-2-Clause
#
#  user.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class User < ActiveRecord::Base
  belongs_to :company
  belongs_to :group

  validates :github_id, presence: true, uniqueness: true
end
