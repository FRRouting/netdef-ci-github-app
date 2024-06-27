#  SPDX-License-Identifier: BSD-2-Clause
#
#  retry_stage.rb
#  Part of NetDEF CI System
#
#  Copyright (c) 2024 by
#  Network Device Education Foundation, Inc. ("NetDEF")
#
#  frozen_string_literal: true

require 'otr-activerecord'

class RetryStage < ActiveRecord::Base
  belongs_to :check_suite
  belongs_to :stage
  serialize :failure_jobs, Array
  validates :failure_jobs, presence: true
  validates :check_suite, presence: true
  validates :stage, presence: true
  validates :created_at, presence: true
  validates :updated_at, presence: true
  validates :id, presence: true
end
