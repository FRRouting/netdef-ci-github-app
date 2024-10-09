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

class Organization < ActiveRecord::Base
  has_many :github_users

  # :nocov:
  def inspect
    "Organization id: #{id}, name: #{name}, contact_email: #{contact_email}, " \
      "contact_name: #{contact_name}, url: #{url} " \
      "created_at: #{created_at}, updated_at: #{updated_at}"
  end
  # :nocov:
end
