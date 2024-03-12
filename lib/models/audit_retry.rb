#  SPDX-License-Identifier: BSD-2-Clause
#
#  audit_retry.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class AuditRetry < ActiveRecord::Base
  has_and_belongs_to_many :ci_jobs
  belongs_to :check_suite
end

