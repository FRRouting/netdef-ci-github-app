#  SPDX-License-Identifier: BSD-2-Clause
#
#  pull_request_subscribe.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2023 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class PullRequestSubscribe < ActiveRecord::Base
  belongs_to :pull_request
end
