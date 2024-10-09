#  SPDX-License-Identifier: BSD-2-Clause
#
#  github_user_info.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class GithubUser < ActiveRecord::Base
  has_many :pull_requests, dependent: :nullify
  has_many :check_suites, dependent: :nullify
  has_many :audit_retries, dependent: :nullify

  belongs_to :organization
end
