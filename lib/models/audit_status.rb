#  SPDX-License-Identifier: BSD-2-Clause
#
#  audit_status.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class AuditStatus < ActiveRecord::Base
  enum status: { queued: 0, in_progress: 1, success: 2, refresh: 3, cancelled: -1, failure: -2, skipped: -3 }

  belongs_to :auditable, polymorphic: true
end
